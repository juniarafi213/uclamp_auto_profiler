#!/usr/bin/env bash
# ==============================================================================
# Build Script for UCLAMP Auto Profiler Flashable Module ZIP
# ==============================================================================

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${DIR}/uclamp_auto_profiler.zip"

mkdir -p "${DIR}/bin"

echo "[*] Checking Rust daemon (uclampd)..."
if [ -d "${DIR}/uclampd" ] && command -v cargo >/dev/null 2>&1; then
    echo "[*] Building uclampd with Cargo for aarch64-unknown-linux-musl..."
    (
        cd "${DIR}/uclampd"
        cargo build --release --target aarch64-unknown-linux-musl
    )
    if [ -f "${DIR}/uclampd/target/aarch64-unknown-linux-musl/release/uclampd" ]; then
        cp "${DIR}/uclampd/target/aarch64-unknown-linux-musl/release/uclampd" "${DIR}/bin/uclampd"
        if command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
            aarch64-linux-gnu-strip "${DIR}/bin/uclampd"
        elif command -v llvm-strip >/dev/null 2>&1; then
            llvm-strip "${DIR}/bin/uclampd"
        fi
        chmod 755 "${DIR}/bin/uclampd"
        echo "    ✓ bin/uclampd compiled ($(du -h "${DIR}/bin/uclampd" | cut -f1))"
    fi
else
    echo "[!] cargo not found or local build skipped. Checking existing bin/uclampd..."
    if [ -f "${DIR}/bin/uclampd" ]; then
        echo "    ✓ using prebuilt bin/uclampd ($(du -h "${DIR}/bin/uclampd" | cut -f1))"
    else
        echo "    ! bin/uclampd not present (will be built by GitHub Actions CI)"
    fi
fi

echo "[*] Checking Encore FAS native helper..."
if [ -f "${DIR}/src/fas_governor.c" ]; then
    if command -v clang >/dev/null 2>&1; then
        echo "[*] Compiling bin/fas_governor (ARM64 freestanding static binary)..."
        clang --target=aarch64-linux-gnu -fuse-ld=lld -nostdlib -static -O2 -fno-builtin -fno-stack-protector \
            "${DIR}/src/fas_governor.c" -o "${DIR}/bin/fas_governor"
        if command -v llvm-strip >/dev/null 2>&1; then
            llvm-strip "${DIR}/bin/fas_governor"
        fi
        chmod 755 "${DIR}/bin/fas_governor"
        echo "    ✓ bin/fas_governor compiled ($(du -h "${DIR}/bin/fas_governor" | cut -f1))"
    else
        echo "[!] clang not found, using existing prebuilt bin/fas_governor"
    fi
fi

echo "[*] Building UCLAMP Auto Profiler flashable zip..."
rm -f "$OUTPUT"

if command -v zip >/dev/null 2>&1; then
    (cd "$DIR" && zip -r -9 "$OUTPUT" . -x "*.git*" "*.zip*" "build.sh" ".github/*" "src/*" "include/*" "uclampd/*")
else
    python3 -c "
import zipfile, os

src_dir = '$DIR'
zip_path = '$OUTPUT'
ignore_prefixes = ['.git', '.github', 'src', 'include', 'uclampd', 'target']
ignore_files = ['build.sh', 'uclamp_auto_profiler.zip']

with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(src_dir):
        # Filter directories
        dirs[:] = [d for d in dirs if not any(d.startswith(p) for p in ignore_prefixes)]
        for f in files:
            if f in ignore_files or f.endswith('.zip') or f.endswith('.swp'):
                continue
            full_path = os.path.join(root, f)
            rel_path = os.path.relpath(full_path, src_dir)
            zf.write(full_path, rel_path)
"
fi

echo "[✓] Build complete: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
