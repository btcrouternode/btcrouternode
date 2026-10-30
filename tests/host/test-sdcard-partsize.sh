#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Verify SD card GPT "production" partition matches ROOTFS_PARTSIZE_MIB (R5b).
# Usage: test-sdcard-partsize.sh <targets/mediatek/filogic dir> <expected_mib>
set -euo pipefail

DIR="${1:?targets dir}"
EXPECT_MIB="${2:?expected MiB}"
IMG_GZ="$(ls -1 "$DIR"/*bananapi_bpi-r4-sdcard.img.gz 2>/dev/null | head -1 || true)"
if [[ -z "$IMG_GZ" ]]; then
  IMG_GZ="$(ls -1 "$DIR"/*sdcard.img.gz 2>/dev/null | head -1 || true)"
fi
[[ -n "$IMG_GZ" && -f "$IMG_GZ" ]] || { echo "FAIL: no sdcard.img.gz in $DIR"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Only need GPT + early partitions; production starts at 64MiB and is EXPECT_MIB long.
# Read first 80MiB + a small trailer via sparse extract of partition table from gzip stream.
python3 - "$IMG_GZ" "$EXPECT_MIB" <<'PY'
import gzip, struct, sys

path, expect_mib = sys.argv[1], int(sys.argv[2])
expect = expect_mib * 1024 * 1024

with gzip.open(path, "rb") as f:
    # Protective MBR + primary GPT header at LBA1; entries at LBA2..
    data = f.read(1024 * 1024)  # 1 MiB is enough for GPT

if len(data) < 1024:
    print("FAIL: image too short"); sys.exit(1)

# GPT header at LBA 1 (offset 512)
hdr = data[512:512+92]
if hdr[0:8] != b"EFI PART":
    print("FAIL: no GPT header"); sys.exit(1)

part_entry_lba = struct.unpack_from("<Q", hdr, 72)[0]
num_entries = struct.unpack_from("<I", hdr, 80)[0]
entry_size = struct.unpack_from("<I", hdr, 84)[0]
entries_off = part_entry_lba * 512

found = None
for i in range(num_entries):
    off = entries_off + i * entry_size
    ent = data[off:off+entry_size]
    if len(ent) < 56:
        break
    type_guid = ent[0:16]
    if type_guid == b"\x00" * 16:
        continue
    name = ent[56:56+72].decode("utf-16-le", "replace").split("\x00", 1)[0]
    first_lba, last_lba = struct.unpack_from("<QQ", ent, 32)
    size = (last_lba - first_lba + 1) * 512
    if name == "production":
        found = (first_lba, last_lba, size)
        break

if not found:
    print("FAIL: production partition not found in GPT")
    sys.exit(1)

first, last, size = found
print(f"OK: production LBA {first}-{last} size={size} ({size/1024/1024:.1f} MiB)")
print(f"    expected={expect} ({expect_mib} MiB)")
if size != expect:
    print(f"FAIL: production size {size} != expected {expect}")
    sys.exit(1)
# Production must start at 64MiB (filogic mt798x-gpt)
if first * 512 != 64 * 1024 * 1024:
    print(f"FAIL: production start LBA {first} not at 64MiB")
    sys.exit(1)
print("PASS: SD GPT production matches eMMC-target ROOTFS_PARTSIZE (R5b)")
PY
