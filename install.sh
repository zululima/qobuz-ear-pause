#!/bin/zsh
# Builds qobuz-ear-pause and (re)starts it as a LaunchAgent for this user.
set -euo pipefail

here=${0:A:h}
label=local.qobuz-ear-pause
bin=$HOME/.local/bin/qobuz-ear-pause
plist=$HOME/Library/LaunchAgents/$label.plist
domain=gui/$(id -u)

mkdir -p "$here/build" "$HOME/.local/bin"
swiftc -O -o "$here/build/qobuz-ear-pause" "$here/main.swift"
# An ad-hoc signature's default requirement is the build's hash, which ties the Accessibility
# grant to one build. Naming the identifier instead keeps the grant across rebuilds.
codesign --force --sign - --identifier "$label" \
  -r="designated => identifier \"$label\"" "$here/build/qobuz-ear-pause"

launchctl bootout "$domain/$label" 2>/dev/null || true
install -m 755 "$here/build/qobuz-ear-pause" "$bin"

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$bin</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/qobuz-ear-pause.log</string>
</dict>
</plist>
EOF

launchctl bootstrap "$domain" "$plist"
echo "installed $bin and started $label"
