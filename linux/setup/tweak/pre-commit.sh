#!/bin/bash
# pre-commit (Linux tier): a wrapper that delegates to the tier-portable macOS
# script (macos/setup/tweak/pre-commit.sh), which runs on Linux unchanged.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$DIR/../../../macos/setup/tweak/pre-commit.sh" "$@"
