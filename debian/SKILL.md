---
name: mcp-server-relate
description: Query a local Relate graph database (Cypher 25) through MCP. Use when the user wants to explore or query graph data stored in Relate.
---

The server runs `relate serve --mcp stdio` on the database in `MCP_SERVER_RELATE_DATABASE`.
It is read-only by default in mcprack (`MCP_SERVER_RELATE_READ_ONLY=true`); disable that
only when the user explicitly wants writes.
