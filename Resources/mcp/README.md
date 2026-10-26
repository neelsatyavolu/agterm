# agmux's MCP servers, shipped with agterm

`agmux-memory-mcp.bundle.mjs` and `agmux-consult-mcp.bundle.mjs` are agmux's project-memory and
consult servers, built from agmux's `sidecar/` (commit f3d451cc) and copied here unchanged so they
work without agmux installed. When agmux is installed, agterm uses agmux's own copies instead, so
memory behaves exactly as it does in agmux. They're under agmux's license (`LICENSE` here), not
agterm's MIT license.

To update: `cd ../agmux/sidecar && npm ci && npm run build`, then copy the two files from `dist/`.
