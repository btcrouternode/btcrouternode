#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-EMMC-GPT — G4/D6 (review 2026-10-11): the eMMC primary GPT is generated
# from the SD image in `make image` and verified, not trusted as a committed
# blob. Uses synthetic images (no build needed).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
X="$ROOT/build/extract-emmc-gpt.py"
REF="$ROOT/factory/emmc-gpt-primary-64.bin"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkimg() { # BLOB OUT.gz — blob placed at 56 MiB in a sparse image
	python3 -I - "$1" "$2" <<'PY'
import gzip, sys
blob = open(sys.argv[1], "rb").read()
with gzip.open(sys.argv[2], "wb", compresslevel=1) as g:
    z = b"\0" * (1 << 20)
    for _ in range(56):
        g.write(z)
    g.write(blob)
    g.write(z)
PY
}
mutate() { # IN OUT OFFSET HEXBYTES
	python3 -I - "$@" <<'PY'
import sys
b = bytearray(open(sys.argv[1], "rb").read())
off = int(sys.argv[3]); new = bytes.fromhex(sys.argv[4])
b[off:off + len(new)] = new
open(sys.argv[2], "wb").write(b)
PY
}
run() { python3 -I "$X" "$@" >"$W/out" 2>&1; }

mkimg "$REF" "$W/good.img.gz"
run "$W/good.img.gz" 7391 "$W/g.bin" "$REF" || { cat "$W/out"; fail "good image must verify"; }
cmp -s "$W/g.bin" "$REF" || fail "extracted blob must equal the reference"
grep -q 'guard=20f8e800' "$W/out" || fail "guard bytes must be reported (installer F28 check)"
pass "good image: verified, extracted, matches the committed reference"

run "$W/good.img.gz" 7408 "$W/x.bin" && fail "7408 MiB (F28 overflow) must be rejected"
grep -q 'last usable LBA' "$W/out" || fail "wrong partsize message"
mutate "$REF" "$W/crc.bin" 600 ff; mkimg "$W/crc.bin" "$W/crc.img.gz"
run "$W/crc.img.gz" 7391 "$W/x.bin" && fail "corrupted header must be rejected"
mutate "$REF" "$W/ent.bin" 1100 ff; mkimg "$W/ent.bin" "$W/ent.img.gz"
run "$W/ent.img.gz" 7391 "$W/x.bin" && fail "corrupted entry array must be rejected"
grep -q 'entry array CRC' "$W/out" || fail "entry CRC message"
mutate "$REF" "$W/lba0.bin" 0 "4546492050415254"; mkimg "$W/lba0.bin" "$W/lba0.img.gz"
run "$W/lba0.img.gz" 7391 "$W/x.bin" && fail "EFI PART at LBA 0 (F28 hand-built) must be rejected"
mutate "$REF" "$W/mbr.bin" 510 0000; mkimg "$W/mbr.bin" "$W/mbr.img.gz"
run "$W/mbr.img.gz" 7391 "$W/x.bin" && fail "missing MBR signature must be rejected"
pass "rejected: wrong ROOTFS_PARTSIZE (7408), header CRC, entry CRC, EFI@LBA0, no MBR"

# reference drift: fails unless UPDATE_GPT_REF=1
cp "$REF" "$W/ref.bin"; mutate "$W/ref.bin" "$W/ref.bin" 2000 01
run "$W/good.img.gz" 7391 "$W/x.bin" "$W/ref.bin" && fail "a stale committed reference must fail the build"
UPDATE_GPT_REF=1 run "$W/good.img.gz" 7391 "$W/x.bin" "$W/ref.bin" || fail "UPDATE_GPT_REF=1 must refresh the reference"
cmp -s "$W/ref.bin" "$REF" || fail "refreshed reference must equal the image GPT"
pass "stale reference fails the build; UPDATE_GPT_REF=1 refreshes it"

grep -q 'extract-emmc-gpt.py' "$ROOT/build/publish-versioned-images.sh" || fail "make image must generate the GPT"
grep -q 'VER_GPT' "$ROOT/build/publish-versioned-images.sh" || fail "GPT blob must be in the release checksums"
pass "make image generates + checksums the eMMC GPT"
echo "ALL PASS: test-emmc-gpt (T-EMMC-GPT)"
