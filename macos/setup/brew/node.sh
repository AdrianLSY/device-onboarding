#!/bin/bash
set -e

# Node.js: builds the KiCad MCP server (npm) and runs mcp-remote, the bridge
# Claude Desktop uses to reach Part-DB. See setup/tweak/kicad-mcp.sh and
# setup/tweak/part-db-mcp.sh.
brew install node
