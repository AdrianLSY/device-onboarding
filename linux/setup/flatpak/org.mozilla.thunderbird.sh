#!/bin/bash
set -e

# Lowercase t: Flathub end-of-lifed org.mozilla.Thunderbird and rebases it onto
# org.mozilla.thunderbird_esr. This id is the regular release channel.
flatpak install -y flathub org.mozilla.thunderbird
