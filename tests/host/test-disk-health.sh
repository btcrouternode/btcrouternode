#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-DISK-HEALTH — M.2 drive health (disk-health.sh), run by the IMAGE's own
# BusyBox + jsonfilter in a chroot (docker + qemu-aarch64), with a stub
# `nvme` replaying SMART logs. The healthy fixture is the real Kingston NV2
# on the test router (2026-10-22, nvme-cli 2.9.1).
# Also static: wiring into the status loop / status API / UI, nvme-cli in the
# image. SKIPs the device part when the rootfs, docker or binfmt is absent.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
K="$ROOT/files/usr/libexec/knots"
RFS="$ROOT/build/imagebuilder/build_dir/target-aarch64_cortex-a53_musl/root-mediatek"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- static wiring ---
grep -qx 'nvme-cli' "$ROOT/build/packages.txt" || fail "nvme-cli not in build/packages.txt"
grep -q 'disk-health.sh --if-stale' "$ROOT/files/etc/init.d/knots-status" || fail "status loop does not run disk-health"
grep -q 'disk-health.json' "$K/status-api.sh" || fail "status API does not report disk health"
grep -q 'renderDisk' "$ROOT/files/www/knots/app.js" && grep -q 'id="diskBanner"' "$ROOT/files/www/knots/index.html" \
	|| fail "Node Status does not show drive health"
pass "nvme-cli in the image; status loop → disk-health.json → /api/status → Node Status"
grep -qx 'fstrim' "$ROOT/build/packages.txt" || fail "fstrim not in build/packages.txt"
grep -q 'm2-trim.sh' "$ROOT/files/etc/init.d/knots-status" || fail "status loop does not run m2-trim"
grep -vE '^[[:space:]]*#' "$K/m2-trim.sh" | grep -qE '(^|[^a-z_])rm |discard' && fail "m2-trim must not delete files or use discard"
grep -q 'discard' "$K/storage-prepare.sh" && fail "the M.2 must not be mounted with discard"
pass "weekly fstrim: package, status loop, no deletes, no discard mount"

skip() { echo "SKIP device part: $*"; echo "ALL PASS: test-disk-health (T-DISK-HEALTH, static only)"; exit 0; }
[ -x "$RFS/bin/busybox" ] && [ -x "$RFS/usr/bin/jsonfilter" ] || skip "no Image Builder rootfs (run make image)"
command -v docker >/dev/null 2>&1 || skip "docker not installed"
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || skip "no qemu-aarch64 binfmt"
docker image inspect alpine:3.20 >/dev/null 2>&1 || skip "alpine:3.20 image not present"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cp "$K/disk-health.sh" "$W/dh.sh"
cat >"$W/t.sh" <<'EOF'
#!/bin/sh
# runs inside the image chroot; /mnt is the test workspace
set -u
T=/mnt/w
smart() { # CW TEMPK SPARE PCT MEDIA UNSAFE
	cat >$T/smart.json <<J
{
  "critical_warning":$1,
  "temperature":$2,
  "avail_spare":$3,
  "spare_thresh":10,
  "percent_used":$4,
  "data_units_read":306322021,
  "data_units_written":16285799,
  "power_cycles":146,
  "power_on_hours":2108,
  "unsafe_shutdowns":$6,
  "media_errors":$5,
  "num_err_log_entries":0,
  "warning_temp_time":3660,
  "critical_comp_time":8833
}
J
}
reset() {
	rm -rf $T; mkdir -p $T/sys/nvme0 $T/hwmon/hwmon1 $T/ext4 $T/mnt $T/out $T/bin
	printf 'KINGSTON SNV2S1000G                     \n' >$T/sys/nvme0/model
	printf '50026B778579D086    \n' >$T/sys/nvme0/serial
	echo SBM02103 >$T/sys/nvme0/firmware_rev; echo live >$T/sys/nvme0/state
	echo nvme >$T/hwmon/hwmon1/name; echo 40850 >$T/hwmon/hwmon1/temp1_input
	echo 82850 >$T/hwmon/hwmon1/temp1_max; echo 89850 >$T/hwmon/hwmon1/temp1_crit
	echo 0 >$T/ext4/errors_count
	echo "/dev/nvme0n1p1 $T/mnt ext4 rw,noatime 0 0" >$T/mounts
	printf '#!/bin/sh\n[ -f %s/nvme.fail ] && exit 1\ncat %s/smart.json\n' $T $T >$T/bin/nvme; chmod +x $T/bin/nvme
	smart 0 314 100 0 0 121
}
run() { # NAME [args]
	n=$1; shift
	PATH=$T/bin:/usr/bin:/bin:/usr/sbin:/sbin NVME=nvme KNOTS_SYSNVME=$T/sys/nvme0 KNOTS_HWMON=$T/hwmon \
	KNOTS_MNT=$T/mnt KNOTS_EXT4=$T/ext4 KNOTS_MOUNTS=$T/mounts KNOTS_STATUS_DIR=$T/out \
		sh /mnt/dh.sh "$@" || echo "RC_FAIL $n"
	cp $T/out/disk-health.json /mnt/res/$n.json
}
mkdir -p /mnt/res
reset; run healthy
smart 0 314 100 0 0 122; run power_loss
smart 0 314 100 85 0 122; run wear_high
smart 0 314 100 0 1 122; run media_1
smart 0 314 100 0 12 122; run media_12
reset; smart 1 314 9 0 0 121; run spare_low
reset; smart 8 314 100 0 0 121; run read_only_media
reset; echo 85000 >$T/hwmon/hwmon1/temp1_input; run temp_warn
reset; echo 91000 >$T/hwmon/hwmon1/temp1_input; run temp_crit
reset; echo "/dev/nvme0n1p1 $T/mnt ext4 ro,noatime 0 0" >$T/mounts; run fs_ro
reset; echo 2 >$T/ext4/errors_count; run ext4_err
reset; touch $T/nvme.fail; run no_smart
reset; rm -rf $T/sys/nvme0; run missing
reset; run stale_a; smart 0 314 100 85 0 121; run stale_b --if-stale 300
EOF
mkdir -p "$W/res"
out=$(docker run --rm -v "$RFS":/rootfs:ro -v "$W":/rootfs/mnt --tmpfs /rootfs/dev:rw,dev,size=64k \
	--tmpfs /rootfs/tmp:rw,size=8m alpine:3.20 \
	sh -c "mknod -m 666 /rootfs/dev/null c 1 3 && chroot /rootfs /bin/busybox sh /mnt/t.sh; rc=\$?; chown -R $(id -u):$(id -g) /rootfs/mnt; exit \$rc" 2>&1) || fail "image run: $out"
echo "$out" | grep -q RC_FAIL && fail "disk-health exited non-zero: $out"

python3 - "$W/res" <<'PY' || exit 1
import json, sys, os
d = sys.argv[1]
def r(n):
    with open(os.path.join(d, n + ".json")) as f:
        return json.load(f)   # every result must be valid JSON
fails = []
def expect(n, level, reason=None, **kv):
    x = r(n)
    if x["level"] != level: fails.append(f"{n}: level {x['level']} want {level} ({x['reasons']})")
    if reason and reason not in x["reasons"]: fails.append(f"{n}: reasons {x['reasons']} lack {reason}")
    for k, v in kv.items():
        if x.get(k) != v: fails.append(f"{n}: {k}={x.get(k)!r} want {v!r}")
h = r("healthy")
expect("healthy", "healthy", present=True, model="KINGSTON SNV2S1000G", serial="50026B778579D086",
       temp_c=40, warn_c=82, crit_c=89, percent_used=0, avail_spare=100, media_errors=0,
       unsafe_shutdowns=121, power_loss_recent=False, data_written_gb=8338, smart=True)
if h["reasons"]: fails.append(f"healthy: reasons {h['reasons']}")
expect("power_loss", "healthy", power_loss_recent=True, unsafe_shutdowns=122)
expect("wear_high", "attention", "wear_high", percent_used=85)
expect("media_1", "attention", "media_errors", media_errors_baseline=0)
expect("media_12", "at_risk", "media_errors")
expect("spare_low", "at_risk", "spare_low")
expect("read_only_media", "failed", "media_read_only")
expect("temp_warn", "attention", "temperature_warning", temp_c=85)
expect("temp_crit", "at_risk", "temperature_critical", temp_c=91)
expect("fs_ro", "failed", "read_only")
expect("ext4_err", "attention", "filesystem_errors", ext4_errors=2)
expect("no_smart", "attention", "smart_unavailable", smart=False, temp_c=40)
expect("missing", "failed", "drive_missing", present=False)
if r("stale_b")["percent_used"] != 0: fails.append("--if-stale re-read SMART on a fresh result")
if fails:
    print("FAIL: " + "\n      ".join(fails)); sys.exit(1)
PY
pass "image BusyBox + jsonfilter: healthy (real NV2 values), power loss notice, wear, media errors vs baseline, spare, read-only, temperature, ext4, no SMART, missing drive, --if-stale"
# --- weekly TRIM (m2-trim.sh) on the image's BusyBox, stub fstrim ---
cp "$K/m2-trim.sh" "$W/trim.sh"
cat >"$W/t2.sh" <<'T2EOF'
#!/bin/sh
set -u
T=/mnt/w2; rm -rf $T; mkdir -p $T/mnt/blocks $T/out $T/bin /mnt/res2
echo keep >$T/mnt/blocks/blk00000.dat
echo "/dev/nvme0n1p1 $T/mnt ext4 rw,noatime 0 0" >$T/mounts
cat >$T/bin/fstrim <<S
#!/bin/sh
echo "\$*" >>$T/calls
[ -f $T/fail ] && { echo "FITRIM: not supported"; exit 1; }
echo "\$2: 12.3 GiB (13207024640 bytes) trimmed"
S
chmod +x $T/bin/fstrim
# stand-in for node-impl-lib.sh: like the real one it sets MNT (must not leak)
cat >$T/lib.sh <<S
MNT=/mnt/bitcoin
read_node_busy() { [ -f $T/busy ] && echo "true|install|x" || echo "false||"; }
S
tr() { # NAME HOUR NOW
	PATH=$T/bin:/usr/bin:/bin:/usr/sbin:/sbin FSTRIM=fstrim KNOTS_MNT=$T/mnt KNOTS_MOUNTS=$T/mounts \
	KNOTS_STATUS_DIR=$T/out KNOTS_HOUR=$2 KNOTS_NOW=$3 KNOTS_NODE_LIB=$T/lib.sh sh /mnt/trim.sh || echo "RC_FAIL $1"
	echo "$1 calls=$(cat $T/calls 2>/dev/null | wc -l)" >>/mnt/res2/log
}
D=1800000000
touch $T/busy; tr busy 03 $D; rm -f $T/busy
tr day 14 $D
tr night_first 03 $D
tr night_again 04 $((D + 3600))
tr next_day_night 03 $((D + 86400))
tr week_later 03 $((D + 7 * 86400))
echo "/dev/nvme0n1p1 $T/mnt ext4 ro,noatime 0 0" >$T/mounts; tr read_only 03 $((D + 21 * 86400))
: >$T/mounts; tr unmounted 03 $((D + 28 * 86400))
echo "/dev/nvme0n1p1 $T/mnt ext4 rw,noatime 0 0" >$T/mounts; touch $T/fail; tr fails 03 $((D + 35 * 86400))
tr fails_retry 03 $((D + 35 * 86400 + 60))
cp $T/mnt/.disk-health/last-trim /mnt/res2/stamp; cp $T/out/m2-trim.json /mnt/res2/trim.json
cat $T/mnt/blocks/blk00000.dat >/mnt/res2/blk; cat $T/calls >/mnt/res2/calls
T2EOF
out=$(docker run --rm -v "$RFS":/rootfs:ro -v "$W":/rootfs/mnt --tmpfs /rootfs/dev:rw,dev,size=64k \
	--tmpfs /rootfs/tmp:rw,size=8m alpine:3.20 \
	sh -c "mknod -m 666 /rootfs/dev/null c 1 3 && chroot /rootfs /bin/busybox sh /mnt/t2.sh; rc=\$?; chown -R $(id -u):$(id -g) /rootfs/mnt; exit \$rc" 2>&1) || fail "image trim run: $out"
echo "$out" | grep -q RC_FAIL && fail "m2-trim exited non-zero: $out"
want="busy calls=0
day calls=0
night_first calls=1
night_again calls=1
next_day_night calls=1
week_later calls=2
read_only calls=2
unmounted calls=2
fails calls=3
fails_retry calls=3"
got=$(sed 's/  */ /g; s/= */=/' "$W/res2/log")
[ "$got" = "$want" ] || fail "trim schedule: $got"
grep -q '^rc=1$' "$W/res2/stamp" && python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['rc']==1 and 'not supported' in d['result']" "$W/res2/trim.json" \
	|| fail "failed trim not recorded: $(cat "$W/res2/stamp")"
[ "$(cat "$W/res2/blk")" = keep ] || fail "blockchain file changed"
grep -qv -- "-v /mnt/w2/mnt$" "$W/res2/calls" && fail "fstrim called on a path other than the configured mount: $(cat "$W/res2/calls")"
[ -f "$W/w2/mnt/.disk-health/last-trim" ] || fail "trim stamp not on the configured mount"
pass "weekly trim on the image's BusyBox: night only, once a week, catches up, skips busy/read-only/unmounted, records failures, files untouched, node library cannot redirect it"

echo "ALL PASS: test-disk-health (T-DISK-HEALTH)"
