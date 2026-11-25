#!/bin/bash
# Builds agterm-worker.exe, the Windows PC side of Settings → Macs & PCs, from this Mac:
# a 64-bit Windows (x86_64-pc-windows-gnu) release build with mingw-w64, copied to
# .build/windows/agterm-worker.exe. ARM Windows PCs run it under emulation.
set -euo pipefail

cd "$(dirname "$0")/.."
target=x86_64-pc-windows-gnu

if ! rustup target list --installed | grep -qx "$target"; then
    rustup target add "$target"
fi
if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
    echo "windows-worker: installing mingw-w64 (the Windows C toolchain OpenSSL builds with)…" >&2
    brew install mingw-w64
fi

(
    cd windows-worker
    CC_x86_64_pc_windows_gnu=x86_64-w64-mingw32-gcc \
    AR_x86_64_pc_windows_gnu=x86_64-w64-mingw32-ar \
    CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc \
        cargo build --release --target "$target"
)

mkdir -p .build/windows
cp "windows-worker/target/$target/release/agterm-worker.exe" .build/windows/agterm-worker.exe
ls -lh .build/windows/agterm-worker.exe
