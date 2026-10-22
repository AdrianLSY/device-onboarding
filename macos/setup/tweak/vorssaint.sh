#!/bin/bash
set -e

# Vorssaint: CPU, GPU and memory in the menu bar in place of its icon (the
# readouts open its panel; the icon returns only for an update), quit apps when
# their last window closes, and no mouse acceleration. A feature runs only when
# its featureAvailable.<id> key (the Features hub's install switch) and its own
# enable key are both on.
DOMAIN=com.vorssaint.utils

# Vorssaint's first launch resets every featureAvailable key to its Essential
# preset, so writing them before then is wasted. Wait for that first run.
if [ "$(defaults read "$DOMAIN" hasOnboarded 2>/dev/null)" != "1" ]; then
    echo "Vorssaint has not finished its first-run setup yet."
    echo "Open Vorssaint, finish its setup, then run this tweak again:"
    echo "  $0"
    exit 0
fi

# Quit Vorssaint so it reads the new values on relaunch rather than racing them.
running=false
if pgrep -xq Vorssaint; then
    running=true
    osascript -e 'quit app "Vorssaint"'
    for _ in $(seq 50); do pgrep -xq Vorssaint || break; sleep 0.1; done
fi

for feature in autoQuit mouseAcceleration \
    monitorCPU monitorGPU monitorMemory; do
    defaults write "$DOMAIN" "featureAvailable.$feature" -bool true
done
for key in autoQuitEnabled mouseAccelerationDisabled \
    menuBarCPU menuBarGPU menuBarMemory menuBarHideIconWithMetrics; do
    defaults write "$DOMAIN" "$key" -bool true
done

# AeroSpace does focus follows mouse (focus-follows-mouse.enabled), which has no
# delay; Vorssaint's waits at least 100 ms. Keep Vorssaint's off so the two
# don't both move focus.
defaults write "$DOMAIN" featureAvailable.focusFollowsMouse -bool false
defaults write "$DOMAIN" focusFollowsMouseEnabled -bool false

if $running; then open -a Vorssaint; fi
