# agmux's MCP servers, shipped with agterm

`agmux-memory-mcp.bundle.mjs` and `agmux-consult-mcp.bundle.mjs` are agmux's project-memory and
consult servers, built from agmux's `sidecar/` and copied here unchanged. agterm always runs these
copies, never the ones inside an installed agmux.app, so agmux can be uninstalled. For folders agmux
knows, agterm points this memory server at agmux's own stores in `~/.agmux/projects`, which it reads
and writes in the same format as agmux. The memory server is from agmux commit f3d451cc (byte for byte
the copy agmux.app ships); the consult server is from agmux commit 1aeffdff, which adds the board,
the team session tools and `--answer-team-ask`.
They're under agmux's license (`LICENSE` here), not
agterm's MIT license.

To update: `cd ../agmux/sidecar && npm ci && npm run build`, then copy the two files from `dist/`.
Check that a new memory server still reads stores written by the old one before shipping it.
