#!/bin/sh
# MCP stdio launcher for Relate. Env: MCP_SERVER_RELATE_DATABASE,
# MCP_SERVER_RELATE_READ_ONLY (default true; false enables writes).
set -e
case "$1" in
  --version) exec /usr/bin/relate --version ;;
  --help|-h) echo "Usage: mcp-server-relate (env: MCP_SERVER_RELATE_DATABASE, MCP_SERVER_RELATE_READ_ONLY)"; exit 0 ;;
esac
DB="${MCP_SERVER_RELATE_DATABASE:-${XDG_DATA_HOME:-$HOME/.local/share}/relate/mcp}"
mkdir -p "$DB"
# Fail closed: read-only unless explicitly disabled.
case "${MCP_SERVER_RELATE_READ_ONLY:-true}" in
  false|FALSE|False|0|no|NO)
    exec /usr/bin/relate serve --database "$DB" --mcp stdio ;;
  *)
    exec /usr/bin/relate serve --database "$DB" --read-only --mcp stdio ;;
esac
