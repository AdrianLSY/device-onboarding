#!/bin/bash
# part-db-mcp (Windows tier): a real wrapper that delegates to the canonical,
# tier-portable macOS script (macos/setup/tweak/part-db-mcp.sh, written to run on
# Git Bash/MSYS too). Not a symlink, for the reason graphify.sh gives: a symlink
# does not survive the plain USB copy that provisions Windows machines.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$DIR/../../../macos/setup/tweak/part-db-mcp.sh" "$@"
