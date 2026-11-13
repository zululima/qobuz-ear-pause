#!/bin/zsh
# Stops the LaunchAgent and removes what install.sh put in place.
set -uo pipefail

label=local.qobuz-ear-pause
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$label.plist" "$HOME/.local/bin/qobuz-ear-pause"
echo "removed $label; its Accessibility entry stays until you remove it in System Settings"
