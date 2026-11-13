# qobuz-ear-pause

Build and self-check, which changes nothing:

    swiftc -O -o build/qobuz-ear-pause main.swift && build/qobuz-ear-pause --check

Install or reinstall the LaunchAgent `local.qobuz-ear-pause`: `~/Projects/qobuz-ear-pause/install.sh`.
It signs with `designated => identifier "local.qobuz-ear-pause"`, so the Accessibility grant
survives a reinstall. tccd logs "Failed to match existing code requirement" when an entry is tied
to an older build: the user then removes and re-adds it, since toggling keeps the old requirement.

Logs: `~/Library/Logs/qobuz-ear-pause.log`. Ear-outs in the system log:
`/usr/bin/log show --last 1h --predicate 'process == "mediaremoted" AND eventMessage CONTAINS "ear status"'`.
Presses on an AirPod, and which app is Now Playing:
`/usr/bin/log show --last 1h --predicate 'process == "mediaremoted" AND (eventMessage BEGINSWITH "Received command from client" OR eventMessage CONTAINS "ActiveNowPlayingClient changed")'`.

`--pause-now` and any key press pause the music the user is listening to, so ask before running
them while Qobuz plays. A key press from a short-lived process has to stay alive about 0.5 s after
posting, or the event is lost.
