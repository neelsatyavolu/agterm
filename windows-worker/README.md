# agterm-worker

Lets agents on your Mac run tasks on a Windows PC: builds, test suites, anything that needs
Windows. It is the PC side of agterm's Settings → Macs & PCs. It speaks the same link as a Mac
worker, so on the Mac `agterm-remote run --mac <PC> -- "<command>"` works the same way.
Commands run in PowerShell (pwsh 7 when installed, else Windows PowerShell).

## Install

1. Download `agterm-worker.exe` from the [agterm release](https://github.com/neelsatyavolu/agterm/releases/latest).
2. Double-click it. It isn't signed yet, so SmartScreen may stop it: click **More info → Run anyway**.
3. It installs itself for your user (`%LOCALAPPDATA%\agterm`), starts now and at every sign-in, and
   puts its pairing code on the clipboard. In agterm on your Mac, open Settings → Macs & PCs and paste it.
4. If Windows Firewall asks, allow it on private networks. The Mac reaches it on port 47821, by
   `<pc name>.local` or the PC's address on your network (a Tailscale address works too).

No administrator rights are needed.

## Commands

Run these from cmd or PowerShell (`%LOCALAPPDATA%\agterm\agterm-worker.exe` once installed):

| Command | What it does |
|---------|--------------|
| `agterm-worker` or `setup` | Install, start, copy the pairing code |
| `pair` | Print the pairing code |
| `new-code` | Make a new secret and print its code; Macs with the old code must pair again. A running worker uses it from the next connection |
| `serve` | Listen for paired Macs (what runs at sign-in) |
| `uninstall` | Stop it, remove it from sign-in, delete the installed copy and its code |

## How it works

Projects arrive in `%USERPROFILE%\agterm-tasks\<Mac name>\…`. There is no rsync on Windows, so
the Mac compares file lists (`agterm-worker manifest`) and sends what changed as a tar
(`receive`), removes what you deleted (`delete`), and with `--back` copies results home
(`changed`, `pack`). Git-ignored files aren't sent, and what the PC builds stays for next time.
If the Mac disconnects, the command and everything it started are stopped.

## Security

The same as pairing two Macs. The code holds a random 256-bit secret; the link is TLS 1.2 keyed
from it (a pre-shared key, so no certificates), and each connection must also send a token
derived from it. Anyone with the code can run commands as you on this PC, so treat it like a
password. `new-code` unpairs every Mac that has the old one.

## Building

`scripts/windows-worker.sh` cross-compiles it on a Mac (installs the rustup target and mingw-w64
if missing) into `.build/windows/agterm-worker.exe`. `cargo test` here runs on macOS, with
`/bin/sh` standing in for PowerShell.
