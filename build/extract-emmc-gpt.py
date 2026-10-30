#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""G4 / D6 (review 2026-10-11): generate the eMMC primary GPT blob from the
SD image every `make image`, instead of trusting a hand-committed binary.

The SD image embeds the production eMMC GPT (64 sectors = MBR @ LBA 0, GPT
header @ LBA 1, entries @ LBA 2–33) at 56 MiB; factory tools write exactly
these sectors to eMMC (factory/restore-emmc-from-nand.md, F28/F30).

Verifies: MBR signature, "EFI PART" at LBA 1 (not LBA 0 — the F28 hand-built
mistake), header + entry-array CRC32, current LBA 1, and that last-usable /
backup LBAs match ROOTFS_PARTSIZE_MIB (7391 → backup 15267872; 7408 overflowed
the 8GTF4R eMMC). Then requires the committed factory/emmc-gpt-primary-64.bin
to be byte-identical (set UPDATE_GPT_REF=1 to refresh it deliberately).

usage: extract-emmc-gpt.py SDCARD.img.gz ROOTFS_PARTSIZE_MIB OUT.bin [REFERENCE.bin]
"""
import gzip
import os
import struct
import sys
import zlib

OFFSET = 56 * 1024 * 1024        # embedded emmc GPT in the SD image
SIZE = 64 * 512                  # 64 sectors written by emmc_write_hdr
PROD_START_LBA = 131072          # production partition starts at 64 MiB


def fail(msg):
    print(f"FAIL extract-emmc-gpt: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) not in (4, 5):
        fail(__doc__.strip().splitlines()[-1])
    img, partsize, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    ref = sys.argv[4] if len(sys.argv) == 5 else ""

    with gzip.open(img, "rb") as f:
        skipped = 0
        while skipped < OFFSET:
            chunk = f.read(min(4 << 20, OFFSET - skipped))
            if not chunk:
                fail(f"{img} shorter than {OFFSET} bytes")
            skipped += len(chunk)
        blob = f.read(SIZE)
    if len(blob) != SIZE:
        fail(f"short read at 56 MiB ({len(blob)} bytes)")

    if blob[510:512] != b"\x55\xaa":
        fail("no protective MBR signature at LBA 0")
    if blob[0:8] == b"EFI PART":
        fail('"EFI PART" at LBA 0 — hand-built layout (F28), expected MBR @ 0 + header @ 1')
    hdr = blob[512:1024]
    if hdr[0:8] != b"EFI PART":
        fail('GPT header ("EFI PART") missing at LBA 1')
    hsize = struct.unpack_from("<I", hdr, 12)[0]
    hcrc = struct.unpack_from("<I", hdr, 16)[0]
    cur, alt, first, last, ent_lba = struct.unpack_from("<QQQQ", hdr, 24) + (struct.unpack_from("<Q", hdr, 72)[0],)
    nent, esz, ecrc = struct.unpack_from("<III", hdr, 80)
    h = bytearray(hdr[:hsize])
    h[16:20] = b"\0\0\0\0"
    if zlib.crc32(bytes(h)) & 0xFFFFFFFF != hcrc:
        fail("GPT header CRC mismatch")
    ents = blob[ent_lba * 512: ent_lba * 512 + nent * esz]
    if ent_lba != 2 or len(ents) != nent * esz:
        fail(f"partition entries not at LBA 2 within the 64-sector blob (lba={ent_lba})")
    if zlib.crc32(ents) & 0xFFFFFFFF != ecrc:
        fail("partition entry array CRC mismatch")
    if cur != 1:
        fail(f"header current LBA {cur}, want 1")

    want_last = PROD_START_LBA + partsize * 2048 - 1
    want_alt = want_last + 33
    if last != want_last:
        fail(f"last usable LBA {last}, want {want_last} for ROOTFS_PARTSIZE_MIB={partsize}")
    if alt != want_alt:
        fail(f"backup GPT LBA {alt}, want {want_alt} for ROOTFS_PARTSIZE_MIB={partsize} "
             f"(installer guard bytes {struct.pack('<I', alt).hex()})")

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "wb") as f:
        f.write(blob)
    print(f"eMMC GPT OK: {os.path.basename(out)} last={last} backup={alt} "
          f"guard={struct.pack('<I', alt).hex()}")

    if ref:
        cur_ref = open(ref, "rb").read() if os.path.exists(ref) else b""
        if cur_ref != blob:
            if os.environ.get("UPDATE_GPT_REF") == "1":
                with open(ref, "wb") as f:
                    f.write(blob)
                print(f"UPDATED reference {ref} (UPDATE_GPT_REF=1) — commit it")
            else:
                fail(f"{ref} differs from the GPT in this image — factory docs/tools would "
                     "write a different table. Re-run with UPDATE_GPT_REF=1 and commit, "
                     "after checking why it changed.")
        else:
            print(f"reference {os.path.basename(ref)} matches")


if __name__ == "__main__":
    main()
