# qobuz-ear-pause

Pauses the Qobuz desktop app on macOS when you take your AirPods out of your ears, and makes a
press on an AirPod pause and resume Qobuz instead of opening Apple Music.

AirPods Automatic Ear Detection makes macOS send a Pause command to the playing app. The Qobuz
desktop app (8.3.0, Electron 32) receives it and ignores it, then reloads the track and plays on
when the audio route changes. A press on an AirPod goes to the Now Playing app, and since Qobuz
never reports that it plays, macOS sends it to Apple Music and launches it. This helper fills the
gap.

## Get started

Paste this into Claude Code on a Mac with the Qobuz desktop app:

```text
clone https://github.com/zululima/qobuz-ear-pause into ~/Projects/qobuz-ear-pause, read its readme and claude.md, install it and tell me when to turn on its accessibility switch
```

## How it works

- `main.swift` runs `log stream` on `mediaremoted` and waits for the line it logs when ear detection
  sends a Pause (`[AccessoryController] Sending command ... command = Pause`).
- It then reads the last `Status has changed to ...` line of Qobuz's own log,
  `~/Library/Application Support/Qobuz/logs/rapport_qobuz*.txt`. Only when Qobuz is playing does it
  press the play/pause media key, which Qobuz catches through its own event tap.
- For 5 s afterwards it checks Qobuz's log every half second, while still handling ear events, and
  presses again if Qobuz starts playing on the new audio route, at most three presses in all.
- When the AirPods are back in as before the pause, it presses play/pause again 0.3 s later, but
  only if Qobuz's log shows no status change since the helper paused it, as macOS does for apps it
  pauses.
  macOS never resumes Qobuz itself, since Qobuz does not report its playback to Now Playing.
- Qobuz drops a press that arrives while it reloads the track for the AirPods' audio route. So when
  Qobuz's log shows the reload opening the track within 5 s of the resume, and Qobuz still does not
  play, the helper presses once more.
- It never presses the key when Qobuz has no media-key tap, since macOS would then hand the key to
  Apple Music.
- While Qobuz runs, the helper is the Now Playing app: every second it reports Qobuz's status from
  the same log as its own, titled "Qobuz". A press on an AirPod then reaches the helper, and when
  `mediaremoted` also logged that command as coming from `bluetoothd`, the helper presses
  play/pause for Qobuz. Ear detection's own Pause reaches the helper too and is left to the steps
  above.

## While the screen is locked

Qobuz takes the play/pause key and does nothing with it while the screen is locked, so the helper
mutes the sound instead:

- An ear-out while Qobuz plays mutes the Mac's current output, and each output that takes over
  while muted, such as the speakers once both AirPods are out. Qobuz plays on silently.
- When the AirPods are back in as before, the helper puts back each output's mute setting and the
  music carries on from where it has got to.
- When you unlock with the AirPods still out, the helper presses play/pause, which Qobuz takes
  again, and puts back the mute settings once Qobuz's log shows the pause, or after three presses.
- A press on an AirPod mutes Qobuz too, and a second press unmutes it. Qobuz cannot be started
  while the screen is locked.
- Other sounds are muted along with Qobuz. Stopping the helper puts back the mute settings, but
  a crash leaves the outputs muted.

## Install

It needs Xcode or its command line tools, for `swiftc`. Clone the repository into `~/Projects`:

```zsh
git clone https://github.com/zululima/qobuz-ear-pause ~/Projects/qobuz-ear-pause
```

Then run the install script. It builds the binary into `~/.local/bin/qobuz-ear-pause` and starts the
LaunchAgent `local.qobuz-ear-pause`, which runs at every login.

```zsh
~/Projects/qobuz-ear-pause/install.sh
```

macOS then asks for Accessibility access. Turn qobuz-ear-pause on under System Settings >
Privacy & Security > Accessibility. Until you do, the helper logs each ear-out and does nothing
else. Each key press runs in a new process, so the switch counts from the next ear-out on.

The binary is signed with a requirement that names its identifier, so the switch holds across
rebuilds.

## Check it

```zsh
~/.local/bin/qobuz-ear-pause --check
```

```zsh
tail -f ~/Library/Logs/qobuz-ear-pause.log
```

`--pause-now` runs one pause as if an ear-out had happened.

## Uninstall

```zsh
~/Projects/qobuz-ear-pause/uninstall.sh
```

## Limits

- It depends on two log lines that nobody promises to keep: `mediaremoted`'s in macOS 27.2 and
  Qobuz's in 8.3.0. If an update changes either, the helper stops pausing, and its log shows that
  nothing was triggered or that Qobuz had no status.
- A press goes to whichever app macOS last saw playing. After a video in a browser, the press goes
  to the browser until Qobuz plays again.
- Control Center's Now Playing shows the helper's "Qobuz" entry, and its buttons do nothing: the
  helper presses the key only for commands from `bluetoothd`. A double or triple press, for the
  next or previous track, does nothing either.
- Like macOS, it pauses when the first AirPod comes out. Resuming has no time limit: AirPods put
  back an hour later still resume, as long as nothing in Qobuz changed meanwhile.

## Licence

The code is under the [GNU Affero General Public License 3.0 or later](LICENSE). This README and
`CLAUDE.md` are under [Creative Commons Attribution-ShareAlike 4.0](LICENSE-PROSE).
