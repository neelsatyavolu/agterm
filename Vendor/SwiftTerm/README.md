# SwiftTerm (vendored)

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.20.0 (commit `5d14406`), MIT licensed
(see `LICENSE`), with only the library sources. Vendored so agterm can carry one fix; newer
SwiftTerm releases (1.99+) rewrite this code but need a newer Swift toolchain.

Differences from upstream 1.20.0:

- `LocalProcess.enqueueReceivedData` merges each read into the newest chunk the main queue hasn't
  taken yet (up to 64 KB). A program that writes a line at a time (`seq`, build logs) used to
  queue over a million ~15-byte chunks for 2M lines, and draining that queue shifted the whole
  backlog every 32 chunks. 2M lines of output now take ~2.2 s instead of 2.9–7.5 s.
- `SwiftTermBuildInfo.swift` is a fixed file instead of the git-reading build plugin.
- `Package.swift` declares only the `SwiftTerm` library.
