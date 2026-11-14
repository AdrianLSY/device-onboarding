#!/bin/bash
set -e

# get.pulumi.com installs or upgrades to the latest release, but downloads it
# every time, so skip it when the installed version already is that release.
if command -v pulumi >/dev/null 2>&1; then
    LATEST="$(curl -fsSL https://www.pulumi.com/latest-version)"
    if [[ "$(pulumi version)" == "v$LATEST" ]]; then
        echo "pulumi v$LATEST is the latest release."
        exit 0
    fi
fi
curl -fsSL https://get.pulumi.com | sh
