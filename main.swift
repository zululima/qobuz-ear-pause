import AppKit
import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import MediaPlayer

// mediaremoted logs every AirPods ear status change, and the Pause it sends to the playing app
// when Automatic Ear Detection sees an ear-out. The Qobuz desktop app ignores that Pause, and
// macOS never resumes Qobuz since Qobuz does not report its playback to Now Playing. It also
// logs each command bluetoothd passes on from a press on an AirPod.
let earPredicate = """
    process == "mediaremoted" AND (\
    (eventMessage BEGINSWITH "[AccessoryController] Sending command" \
    AND eventMessage CONTAINS "command = Pause") \
    OR (eventMessage BEGINSWITH "[AccessoryController] Device " \
    AND eventMessage CONTAINS " ear status changed from ") \
    OR (eventMessage BEGINSWITH "Received command from client" \
    AND eventMessage CONTAINS "bundleIdentifier = com.apple.bluetoothd"))
    """
let qobuzLogDir = NSHomeDirectory() + "/Library/Application Support/Qobuz/logs"
let checkInterval: TimeInterval = 0.5
let checks = 10
let resumeDelay: TimeInterval = 0.3
let maxPresses = 3
let notAllowed: Int32 = 3

func say(_ message: String) {
    let stamp = ISO8601DateFormatter.string(
        from: Date(), timeZone: .current,
        formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    FileHandle.standardError.write("\(stamp) \(message)\n".data(using: .utf8)!)
}

func qobuzPID() -> pid_t? {
    var pids = [pid_t](repeating: 0, count: 8192)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0,
            String(cString: path).hasSuffix("Qobuz.app/Contents/MacOS/Qobuz")
        {
            return pid
        }
    }
    return nil
}

// Qobuz grabs the play/pause key through an event tap. Without that tap the key would reach
// macOS instead, which can start Apple Music.
func catchesMediaKeys(_ pid: pid_t) -> Bool {
    var count: UInt32 = 0
    guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return false }
    var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
    guard CGGetEventTapList(count, &taps, &count) == .success else { return false }
    let systemDefined: CGEventMask = 1 << 14
    return taps.prefix(Int(count)).contains {
        $0.tappingProcess == pid && $0.enabled && $0.eventsOfInterest & systemDefined != 0
    }
}

func qobuzTakesKey(_ pid: pid_t) -> Bool {
    if catchesMediaKeys(pid) { return true }
    say("Qobuz is not catching the play/pause key, so it was not pressed")
    return false
}

func pressPlayPause() {
    let playKey = 16
    for (flags, state) in [(0xa00, 0xa), (0xb00, 0xb)] {
        let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
            timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
            data1: (playKey << 16) | (state << 8), data2: -1)
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
    // A process that exits right after posting loses the event.
    Thread.sleep(forTimeInterval: 0.5)
}

func newestQobuzLog() -> URL? {
    let dir = URL(fileURLWithPath: qobuzLogDir)
    let files = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
    return files.filter { $0.lastPathComponent.hasPrefix("rapport_qobuz") }
        .max { modified($0) < modified($1) }
}

func read(_ url: URL, from offset: UInt64?) -> (text: String, end: UInt64)? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let end = try? handle.seekToEnd() else { return nil }
    let start = offset.map { min($0, end) } ?? (end > 65_536 ? end - 65_536 : 0)
    try? handle.seek(toOffset: start)
    let data = (try? handle.readToEnd()) ?? Data()
    return (String(decoding: data, as: UTF8.self), end)
}

func statuses(in text: String) -> [String] {
    text.components(separatedBy: "Status has changed to ").dropFirst()
        .map { String($0.prefix { $0.isLetter }) }
}

func isPlaying(_ status: String?) -> Bool { status == "Playing" || status == "Buffering" }

// Every event is handled on this queue, so the state below needs no locks.
let work = DispatchQueue(label: "qobuz-ear-pause")

final class Session {
    let pid: pid_t
    let log: URL
    let earStatus: String?
    let started = Date()
    var pressOffset: UInt64
    var presses = 1
    var muted = false

    init(pid: pid_t, log: URL, earStatus: String?, pressOffset: UInt64) {
        self.pid = pid
        self.log = log
        self.earStatus = earStatus
        self.pressOffset = pressOffset
    }
}

var session: Session?
var lastChange: (from: String, to: String)?

// Qobuz takes the play/pause key and does nothing with it while the screen is locked, so when its
// Dock menu fails too, a pause then mutes the output instead, along with each output that takes
// over until the unmute.
var mutedOutputs: [AudioObjectID: [(element: UInt32, was: UInt32)]]?

func screenIsLocked() -> Bool {
    (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool
        == true
}

func defaultOutput() -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return device
}

func deviceName(_ device: AudioObjectID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name
    else { return "output \(device)" }
    return name.takeRetainedValue() as String
}

func muteAddress(_ element: UInt32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
        mElement: element)
}

func muteState(_ device: AudioObjectID, _ element: UInt32) -> UInt32? {
    var address = muteAddress(element)
    var settable: DarwinBoolean = false
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectHasProperty(device, &address),
        AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue,
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
    else { return nil }
    return value
}

@discardableResult
func setMute(_ device: AudioObjectID, _ element: UInt32, _ value: UInt32) -> Bool {
    var address = muteAddress(element)
    var value = value
    return AudioObjectSetPropertyData(
        device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
}

// Some outputs have a mute for each channel and none for the whole device. An output that comes
// back, such as the AirPods, is muted again with its first setting kept.
func muteOutput(_ device: AudioObjectID) {
    guard var muted = mutedOutputs, device != kAudioObjectUnknown else { return }
    if let saved = muted[device] {
        for channel in saved { setMute(device, channel.element, 1) }
        return
    }
    var saved: [(element: UInt32, was: UInt32)] = []
    for element in [kAudioObjectPropertyElementMain, 1, 2] {
        guard let was = muteState(device, element), setMute(device, element, 1) else { continue }
        saved.append((element, was))
        if element == kAudioObjectPropertyElementMain { break }
    }
    muted[device] = saved
    mutedOutputs = muted
    say(saved.isEmpty ? "could not mute \(deviceName(device))" : "muted \(deviceName(device))")
}

func muteOutputs() {
    mutedOutputs = mutedOutputs ?? [:]
    muteOutput(defaultOutput())
}

func unmuteOutputs() {
    for (device, saved) in mutedOutputs ?? [:] where !saved.isEmpty {
        for channel in saved { setMute(device, channel.element, channel.was) }
        say("put back the mute setting of \(deviceName(device))")
    }
    mutedOutputs = nil
}

// macOS answers a permission check once per process, so a grant made while the helper runs
// reaches only a new process. Each press therefore runs in one, which the helper does not wait
// for, since it stays alive for a moment after posting the key.
@discardableResult
func press(onFailure: @escaping () -> Void = {}) -> Bool {
    let child = Process()
    child.executableURL = Bundle.main.executableURL
    child.arguments = ["--press"]
    child.terminationHandler = { child in
        guard child.terminationStatus != 0 else { return }
        if child.terminationStatus == notAllowed {
            say("not allowed to press keys: turn on qobuz-ear-pause under Accessibility")
        }
        work.async(execute: onFailure)
    }
    do { try child.run() } catch {
        say("could not run the key press: \(error)")
        return false
    }
    return true
}

func axValue(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        ? value : nil
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    axValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func axTitle(_ element: AXUIElement) -> String { axValue(element, kAXTitleAttribute) as? String ?? "" }

// The Play and Pause items of Qobuz's Dock menu still work while the screen is locked, when
// Qobuz ignores the key. Opened through Accessibility, the menu stays behind the lock screen;
// unlocked it would show, so the key is used then.
func pressDockItem(_ titles: Set<String>) -> Bool {
    guard let dock = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.dock"
    ).first else { return false }
    let app = AXUIElementCreateApplication(dock.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 1)
    guard let tile = axChildren(app).flatMap(axChildren).first(where: { axTitle($0) == "Qobuz" }),
        AXUIElementPerformAction(tile, kAXShowMenuAction as CFString) == .success
    else {
        say("could not open Qobuz's Dock menu")
        return false
    }
    var menu: AXUIElement?
    for _ in 0..<20 where menu == nil {
        menu = axChildren(tile).first { axValue($0, kAXRoleAttribute) as? String == kAXMenuRole }
        if menu == nil { Thread.sleep(forTimeInterval: 0.05) }
    }
    guard let menu else {
        say("Qobuz's Dock menu did not open")
        return false
    }
    guard let item = axChildren(menu).first(where: { titles.contains(axTitle($0)) }),
        AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    else {
        AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        say("Qobuz's Dock menu has no \(titles.sorted().joined(separator: " or ")) item")
        return false
    }
    say("pressed \(axTitle(item)) in Qobuz's Dock menu")
    return true
}

func pressPlayPause(_ pid: pid_t, dockItems: Set<String> = ["Play", "Pause"]) -> Bool {
    screenIsLocked() ? pressDockItem(dockItems) : qobuzTakesKey(pid) && press()
}

func pauseQobuzIfPlaying(locked: Bool = false) -> Session? {
    guard let pid = qobuzPID() else {
        say("Qobuz is not running")
        return nil
    }
    guard let log = newestQobuzLog(), let before = read(log, from: nil) else {
        say("no Qobuz log in \(qobuzLogDir)")
        return nil
    }
    let status = statuses(in: before.text).last
    guard isPlaying(status) else {
        say("Qobuz is not playing (\(status ?? "no status"))")
        return nil
    }
    let paused = Session(
        pid: pid, log: log, earStatus: lastChange?.from, pressOffset: before.end)
    if locked {
        if pressDockItem(["Pause"]) { return paused }
        paused.muted = true
        say("the screen is locked, where Qobuz ignores the key, so the output is muted instead")
        muteOutputs()
        return paused
    }
    guard qobuzTakesKey(pid) else { return nil }
    guard press(onFailure: { if session === paused { session = nil } }) else { return nil }
    say("pressed play/pause")
    return paused
}

// Qobuz reloads the track and plays on when the audio route changes, which follows an ear-out
// of both AirPods within about half a second, so its log is watched for a while after a pause.
func watch(_ paused: Session, step: Int = 1) {
    work.asyncAfter(deadline: .now() + checkInterval) {
        guard session === paused, let since = read(paused.log, from: paused.pressOffset) else {
            return
        }
        if let latest = statuses(in: since.text).last, isPlaying(latest),
            paused.presses < maxPresses
        {
            paused.pressOffset = since.end
            paused.presses += 1
            if pressPlayPause(paused.pid, dockItems: ["Pause"]) {
                say("Qobuz went back to \(latest), pressed play/pause again")
            }
        }
        if step < checks { watch(paused, step: step + 1) }
    }
}

func handlePause() {
    say("ear detection asked for a pause")
    resuming = nil
    guard mutedOutputs == nil else { return }
    // An ear-out of both AirPods asks twice, and the watch covers the second.
    if let current = session, Date().timeIntervalSince(current.started) < checkInterval * Double(checks) {
        return
    }
    guard let paused = pauseQobuzIfPlaying(locked: screenIsLocked()) else { return }
    session = paused
    if !paused.muted { watch(paused) }
}

// Like macOS, resume only when nothing in Qobuz has changed since the helper paused it. The
// short wait lets a route change from the AirPods coming back reach Qobuz's log first.
func resume(_ paused: Session) {
    guard lastChange?.to == paused.earStatus else {
        if paused.muted { session = paused }
        return say("AirPods came out again, so Qobuz was not resumed")
    }
    if paused.muted { return unmuteOutputs() }
    guard qobuzPID() == paused.pid, let since = read(paused.log, from: paused.pressOffset) else {
        return say("Qobuz restarted since the pause, so it was not resumed")
    }
    let changes = statuses(in: since.text)
    guard changes == ["Stopped"] else {
        let seen = changes.isEmpty ? "no status" : changes.joined(separator: ", ")
        return say("Qobuz changed since the pause (\(seen)), so it was not resumed")
    }
    guard pressPlayPause(paused.pid, dockItems: ["Play"]) else { return }
    say("pressed play/pause to resume")
    paused.pressOffset = since.end
    resuming = paused
    confirmResume(paused)
}

// Qobuz drops a press that reaches it while it reloads the track for the AirPods' audio route,
// so once a reload has opened the track and Qobuz still does not play, the helper presses again.
var resuming: Session?

func confirmResume(_ resumed: Session, step: Int = 1, reloaded: Bool = false) {
    work.asyncAfter(deadline: .now() + checkInterval) {
        guard resuming === resumed, lastChange?.to == resumed.earStatus,
            let since = read(resumed.log, from: resumed.pressOffset)
        else { return }
        if statuses(in: since.text).contains(where: { isPlaying($0) }) {
            resuming = nil
            return
        }
        if reloaded {
            resuming = nil
            guard pressPlayPause(resumed.pid, dockItems: ["Play"]) else { return }
            return say("Qobuz reloaded the track without playing, pressed play/pause again")
        }
        if step < checks {
            confirmResume(
                resumed, step: step + 1, reloaded: since.text.contains("Open music for track"))
        }
    }
}

func handleChange(from: String, to: String) {
    lastChange = (from, to)
    guard let paused = session, let before = paused.earStatus, to == before else { return }
    session = nil
    say("AirPods back to \(to)")
    work.asyncAfter(deadline: .now() + resumeDelay) { resume(paused) }
}

// After the unlock the key reaches Qobuz again, which has played on muted. The output is unmuted
// once Qobuz's log shows the pause, or after the last press regardless.
let unlockDelay: TimeInterval = 0.5
let pauseCheckDelay: TimeInterval = 1.5

func handleUnlock() {
    guard mutedOutputs != nil else { return }
    guard let paused = session, paused.muted else { return unmuteOutputs() }
    work.asyncAfter(deadline: .now() + unlockDelay) { pauseAfterUnlock(paused) }
}

func pauseAfterUnlock(_ paused: Session, presses: Int = 0, since start: UInt64? = nil) {
    guard session === paused, paused.muted else { return }
    guard qobuzPID() == paused.pid, let now = read(paused.log, from: nil) else {
        session = nil
        return unmuteOutputs()
    }
    let start = start ?? now.end
    guard isPlaying(statuses(in: now.text).last) else {
        paused.muted = false
        paused.pressOffset = start
        return unmuteOutputs()
    }
    guard presses < maxPresses, qobuzTakesKey(paused.pid), press() else {
        session = nil
        if presses == maxPresses { say("Qobuz did not pause after the unlock") }
        return unmuteOutputs()
    }
    say("screen unlocked, pressed play/pause")
    work.asyncAfter(deadline: .now() + pauseCheckDelay) {
        pauseAfterUnlock(paused, presses: presses + 1, since: start)
    }
}

// A press on an AirPod goes to the Now Playing app, and with none macOS launched Music for it.
// The helper is that app while Qobuz runs, and presses the key for Qobuz when a command reaches
// it and mediaremoted logged it as coming from bluetoothd. Ear detection's Pause reaches the
// helper too but has no such line, and stays with handlePause.
let pressWindow: TimeInterval = 2
var buttonHeard: Date?
var commandReached: Date?

func isRecent(_ date: Date?) -> Bool {
    date.map { Date().timeIntervalSince($0) < pressWindow } ?? false
}

func pressForButton() {
    session = nil
    resuming = nil
    guard let pid = qobuzPID() else { return say("AirPods button pressed, but Qobuz is not running") }
    say("AirPods button pressed")
    if mutedOutputs != nil { return unmuteOutputs() }
    guard pressPlayPause(pid) else { return }
    say("pressed play/pause")
}

func handleButton() {
    if isRecent(commandReached) {
        commandReached = nil
        pressForButton()
    } else {
        buttonHeard = Date()
    }
}

func handleCommand() {
    if isRecent(buttonHeard) {
        buttonHeard = nil
        pressForButton()
    } else {
        commandReached = Date()
    }
}

var nowPlaying: (log: URL, end: UInt64, status: String?)?
var reported: MPNowPlayingPlaybackState?

func reportQobuzState() {
    var state = MPNowPlayingPlaybackState.stopped
    if qobuzPID() != nil, let log = newestQobuzLog() {
        let known = nowPlaying?.log == log ? nowPlaying : nil
        if let since = read(log, from: known?.end) {
            let status = statuses(in: since.text).last ?? known?.status
            nowPlaying = (log, since.end, status)
            state = isPlaying(status) ? .playing : .paused
        }
    }
    if state == .playing, mutedOutputs != nil { state = .paused }
    guard state != reported else { return }
    let claim = state == .paused && reported != .playing
    reported = state
    DispatchQueue.main.async {
        let info = MPNowPlayingInfoCenter.default()
        // macOS makes an app the Now Playing app only once it plays.
        if claim { info.playbackState = .playing }
        info.playbackState = state
    }
}

let reporter = DispatchSource.makeTimerSource(queue: work)

func followUnlockAndOutput() {
    DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil
    ) { _ in work.async(execute: handleUnlock) }
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, work
    ) { _, _ in muteOutput(defaultOutput()) }
}

func becomeNowPlaying() {
    let center = MPRemoteCommandCenter.shared()
    for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand] {
        command.addTarget { _ in
            work.async(execute: handleCommand)
            return .success
        }
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "Qobuz"]
    reporter.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(500))
    reporter.setEventHandler(handler: reportQobuzState)
    reporter.resume()
}

func check() {
    let pid = qobuzPID()
    let status = newestQobuzLog().flatMap { read($0, from: nil) }
        .flatMap { statuses(in: $0.text).last }
    print("Qobuz running:           \(pid.map { "yes, pid \($0)" } ?? "no")")
    print("Qobuz status:            \(status ?? "unknown")")
    print("Qobuz catches the key:   \(pid.map(catchesMediaKeys) == true ? "yes" : "no")")
    print("allowed to press keys:   \(CGPreflightPostEventAccess() ? "yes" : "no")")
    print("screen locked:           \(screenIsLocked() ? "yes" : "no")")
    let output = defaultOutput()
    let mute = muteState(output, kAudioObjectPropertyElementMain).map { $0 == 1 ? "muted" : "on" }
    print("output:                  \(deviceName(output)), \(mute ?? "no device mute")")
}

enum EarEvent: Equatable {
    case pause
    case changed(from: String, to: String)
    case button
}

// The first line of `log stream` repeats the predicate, so only parsed events count.
func earEvent(in line: String) -> EarEvent? {
    guard line.hasPrefix("{"),
        let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
        let message = (object as? [String: Any])?["eventMessage"] as? String
    else { return nil }
    if message.hasPrefix("[AccessoryController] Sending command")
        && message.contains("command = Pause")
    {
        return .pause
    }
    if message.hasPrefix("Received command from client"),
        let range = message.range(of: "command = ")
    {
        let command = message[range.upperBound...].prefix { $0.isLetter }
        return ["Play", "Pause", "TogglePlayPause"].contains(command) ? .button : nil
    }
    guard message.hasPrefix("[AccessoryController] Device "),
        let range = message.range(of: " ear status changed from ")
    else { return nil }
    let words = message[range.upperBound...].split(whereSeparator: \.isWhitespace)
    guard words.count >= 3, words[1] == "to" else { return nil }
    return .changed(from: String(words[0]), to: String(words[2]))
}

let stream = Process()

// launchd stops the helper with SIGTERM, and an exit leaves `log stream` running on its own.
func quit() -> Never {
    work.sync { unmuteOutputs() }
    if stream.isRunning { stream.terminate() }
    exit(0)
}

// macOS cannot prompt for the right to post events, so this asks for Accessibility, which
// covers it.
func askForAccessibility() {
    let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    if !AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) {
        say("not allowed to press keys yet: turn on qobuz-ear-pause under Accessibility")
    }
}

func watchEars() -> Never {
    askForAccessibility()
    stream.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    stream.arguments = ["stream", "--style", "ndjson", "--predicate", earPredicate]
    let pipe = Pipe()
    stream.standardOutput = pipe
    do { try stream.run() } catch { say("could not start log stream: \(error)"); exit(1) }
    signal(SIGTERM, SIG_IGN)
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    terminate.setEventHandler { quit() }
    terminate.resume()
    say("watching AirPods ear detection")
    becomeNowPlaying()
    followUnlockAndOutput()
    // Remote commands arrive through the main run loop, so the stream is read on another thread.
    Thread.detachNewThread { readEvents(from: pipe) }
    RunLoop.main.run()
    exit(1)
}

func readEvents(from pipe: Pipe) -> Never {
    let input = fdopen(pipe.fileHandleForReading.fileDescriptor, "r")
    var line: UnsafeMutablePointer<CChar>?
    var capacity = 0
    while getline(&line, &capacity, input) > 0 {
        guard let line, let event = earEvent(in: String(cString: line)) else { continue }
        work.async {
            switch event {
            case .pause: handlePause()
            case .changed(let from, let to): handleChange(from: from, to: to)
            case .button: handleButton()
            }
        }
    }
    say("log stream ended")
    exit(1)
}

switch CommandLine.arguments.dropFirst().first {
case nil: watchEars()
case "--check": check()
case "--pause-now":
    if work.sync(execute: { pauseQobuzIfPlaying() }) != nil { Thread.sleep(forTimeInterval: 1) }
case "--press":
    guard CGPreflightPostEventAccess() else { exit(notAllowed) }
    pressPlayPause()
default:
    print("usage: qobuz-ear-pause [--check | --pause-now]")
    exit(2)
}
