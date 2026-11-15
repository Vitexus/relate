#!/bin/sh
# MCP stdio launcher for Relate. Env: MCP_SERVER_RELATE_DATABASE,
# MCP_SERVER_RELATE_READ_ONLY (true = open read-only).
set -e
case "$1" in
  --version) exec /usr/bin/relate --version ;;
  --help|-h) echo "Usage: mcp-server-relate (env: MCP_SERVER_RELATE_DATABASE, MCP_SERVER_RELATE_READ_ONLY)"; exit 0 ;;
esac
DB="${MCP_SERVER_RELATE_DATABASE:-${XDG_DATA_HOME:-$HOME/.local/share}/relate/mcp}"
mkdir -p "$DB"
if [ "${MCP_SERVER_RELATE_READ_ONLY:-}" = "true" ]; then
  exec /usr/bin/relate serve --database "$DB" --read-only --mcp stdio
fi
exec /usr/bin/relate serve --database "$DB" --mcp stdio
