#!/usr/bin/env bash
# ==============================================================================
# Build Script for UCLAMP Auto Profiler Flashable Module ZIP
# ==============================================================================

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${DIR}/uclamp_auto_profiler.zip"

echo "[*] Building UCLAMP Auto Profiler flashable zip..."
rm -f "$OUTPUT"

if command -v zip >/dev/null 2>&1; then
    (cd "$DIR" && zip -r -9 "$OUTPUT" . -x "*.git*" "*.zip*" "build.sh" ".github/*")
else
    python3 -c "
import zipfile, os

src_dir = '$DIR'
zip_path = '$OUTPUT'
ignore_prefixes = ['.git', '.github']
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
