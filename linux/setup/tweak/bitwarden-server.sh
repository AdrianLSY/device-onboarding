#!/bin/bash
# bitwarden-server (Linux tier): a wrapper that delegates to the tier-portable
# macOS script (macos/setup/tweak/bitwarden-server.sh), which is byte-identical
# to Rooftop's and runs on Linux unchanged.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$DIR/../../../macos/setup/tweak/bitwarden-server.sh" "$@"
