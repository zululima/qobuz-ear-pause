import AppKit
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

    init(pid: pid_t, log: URL, earStatus: String?, pressOffset: UInt64) {
        self.pid = pid
        self.log = log
        self.earStatus = earStatus
        self.pressOffset = pressOffset
    }
}

var session: Session?
var lastChange: (from: String, to: String)?

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

func pauseQobuzIfPlaying() -> Session? {
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
    guard qobuzTakesKey(pid) else { return nil }
    let paused = Session(
        pid: pid, log: log, earStatus: lastChange?.from, pressOffset: before.end)
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
            if press() { say("Qobuz went back to \(latest), pressed play/pause again") }
        }
        if step < checks { watch(paused, step: step + 1) }
    }
}

func handlePause() {
    say("ear detection asked for a pause")
    // An ear-out of both AirPods asks twice, and the watch covers the second.
    if let current = session, Date().timeIntervalSince(current.started) < checkInterval * Double(checks) {
        return
    }
    guard let paused = pauseQobuzIfPlaying() else { return }
    session = paused
    watch(paused)
}

// Like macOS, resume only when nothing in Qobuz has changed since the helper paused it. The
// short wait lets a route change from the AirPods coming back reach Qobuz's log first.
func resume(_ paused: Session) {
    guard lastChange?.to == paused.earStatus else {
        return say("AirPods came out again, so Qobuz was not resumed")
    }
    guard qobuzPID() == paused.pid, let since = read(paused.log, from: paused.pressOffset) else {
        return say("Qobuz restarted since the pause, so it was not resumed")
    }
    let changes = statuses(in: since.text)
    guard changes == ["Stopped"] else {
        let seen = changes.isEmpty ? "no status" : changes.joined(separator: ", ")
        return say("Qobuz changed since the pause (\(seen)), so it was not resumed")
    }
    guard qobuzTakesKey(paused.pid), press() else { return }
    say("pressed play/pause to resume")
}

func handleChange(from: String, to: String) {
    lastChange = (from, to)
    guard let paused = session, let before = paused.earStatus, to == before else { return }
    session = nil
    say("AirPods back to \(to)")
    work.asyncAfter(deadline: .now() + resumeDelay) { resume(paused) }
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
    guard let pid = qobuzPID() else { return say("AirPods button pressed, but Qobuz is not running") }
    say("AirPods button pressed")
    guard qobuzTakesKey(pid), press() else { return }
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
    if work.sync(execute: pauseQobuzIfPlaying) != nil { Thread.sleep(forTimeInterval: 1) }
case "--press":
    guard CGPreflightPostEventAccess() else { exit(notAllowed) }
    pressPlayPause()
default:
    print("usage: qobuz-ear-pause [--check | --pause-now]")
    exit(2)
}
