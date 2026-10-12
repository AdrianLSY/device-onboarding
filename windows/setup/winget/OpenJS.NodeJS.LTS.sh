#!/bin/bash
set -e

# Node.js LTS: builds the KiCad MCP server (npm) and runs mcp-remote, the
# bridge Claude Desktop uses to reach Part-DB. See setup/tweak/kicad-mcp.sh and
# setup/tweak/part-db-mcp.sh. Installs to C:\Program Files\nodejs, which the
# tweaks probe directly: winget PATH changes only reach a new shell.
winget install --id "OpenJS.NodeJS.LTS" -e --source winget --accept-package-agreements --accept-source-agreements
