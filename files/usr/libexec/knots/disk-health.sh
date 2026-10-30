#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# M.2 drive health (owner decision 2026-10-22; docs/PHASE3_STORAGE_RESILIENCE.md
# §3, option 3A). Reads the NVMe SMART/Health log (nvme-cli), the kernel's
# hwmon temperature, the controller state and ext4 error counters, compares
# them with a per-drive baseline recorded the first time the drive is seen,
# and writes /tmp/knots/disk-health.json for Node Status (status-api.sh).
#
#   level: healthy | attention (plan a replacement) | at_risk (replace now)
#          | failed (drive missing / read-only / not responding) | unknown
#   reasons: short codes, worded by the UI (app.js)
#
# Run by the knots-status loop; --if-stale SEC skips work when the last result
# is younger than SEC (SMART is read every 5 min, not every 15 s poll).
# Paths overridable for tests (NVME, KNOTS_SYSNVME, KNOTS_HWMON, KNOTS_MNT, …).
set -u

NVME="${NVME:-nvme}"
DEV="${KNOTS_NVME_DEV:-/dev/nvme0}"
SYSNVME="${KNOTS_SYSNVME:-/sys/class/nvme/nvme0}"
HWMON="${KNOTS_HWMON:-/sys/class/hwmon}"
MNT="${KNOTS_MNT:-/mnt/bitcoin}"
EXT4="${KNOTS_EXT4:-/sys/fs/ext4/nvme0n1p1}"
MOUNTS="${KNOTS_MOUNTS:-/proc/mounts}"
OUT_DIR="${KNOTS_STATUS_DIR:-/tmp/knots}"
OUT="$OUT_DIR/disk-health.json"
NOW="${KNOTS_NOW:-$(date +%s)}"
POWER_LOSS_NOTICE_SEC=$((7 * 86400))

if [ "${1:-}" = "--if-stale" ] && [ -f "$OUT" ]; then
	age=$(( NOW - $(date -r "$OUT" +%s 2>/dev/null || echo 0) ))
	[ "$age" -ge "${2:-300}" ] || exit 0
fi
mkdir -p "$OUT_DIR"

num() { case "$1" in ''|*[!0-9]*) echo "${2:-0}" ;; *) echo "$1" ;; esac; }
trim() { printf '%s' "$1" | tr -d '\r' | sed 's/[[:space:]]*$//; s/"/'"'"'/g'; }

REASONS=""
LEVEL=healthy
rank() { case "$1" in healthy) echo 0 ;; attention) echo 1 ;; at_risk) echo 2 ;; failed) echo 3 ;; *) echo 0 ;; esac; }
raise() { # LEVEL REASON — the worst level wins; each reason listed once
	[ "$(rank "$1")" -gt "$(rank "$LEVEL")" ] && LEVEL=$1
	case ",$REASONS," in *",\"$2\","*) ;; *) REASONS="$REASONS${REASONS:+,}\"$2\"" ;; esac
}

emit() {
	tmp="$OUT.$$"
	cat >"$tmp" <<EOF
{"ok":true,"present":$PRESENT,"level":"$LEVEL","reasons":[$REASONS],"model":"$MODEL","serial":"$SERIAL","firmware":"$FW","state":"$STATE","temp_c":$TEMP_C,"warn_c":$WARN_C,"crit_c":$CRIT_C,"percent_used":$PCT,"avail_spare":$SPARE,"spare_thresh":$THRESH,"media_errors":$MEDIA,"media_errors_baseline":$B_MEDIA,"unsafe_shutdowns":$UNSAFE,"power_loss_recent":$PLOSS,"power_on_hours":$POH,"data_written_gb":$WRITTEN_GB,"warning_temp_minutes":$WTT,"critical_temp_minutes":$CTT,"ext4_errors":$EXT4_ERR,"last_trim":$LAST_TRIM,"smart":$SMART_OK,"ts":$NOW}
EOF
	mv -f "$tmp" "$OUT"
	exit 0
}

PRESENT=false; MODEL=""; SERIAL=""; FW=""; STATE=""
TEMP_C=null; WARN_C=null; CRIT_C=null; PCT=null; SPARE=null; THRESH=null
MEDIA=null; B_MEDIA=null; UNSAFE=null; PLOSS=false; POH=null; WRITTEN_GB=null
WTT=null; CTT=null; EXT4_ERR=null; SMART_OK=false
LAST_TRIM=null
lt=$(sed -n 's/^ts=//p' "$MNT/.disk-health/last-trim" 2>/dev/null)
case "$lt" in ''|*[!0-9]*) ;; *) LAST_TRIM=$lt ;; esac

# --- controller present and responding --------------------------------------
if [ ! -d "$SYSNVME" ]; then
	raise failed drive_missing
	emit
fi
PRESENT=true
MODEL=$(trim "$(cat "$SYSNVME/model" 2>/dev/null)")
SERIAL=$(trim "$(cat "$SYSNVME/serial" 2>/dev/null)")
FW=$(trim "$(cat "$SYSNVME/firmware_rev" 2>/dev/null)")
STATE=$(trim "$(cat "$SYSNVME/state" 2>/dev/null)")
[ "$STATE" = live ] || raise failed controller_not_live

# --- filesystem: mounted, writable, no ext4 errors --------------------------
mline=$(grep " $MNT " "$MOUNTS" 2>/dev/null | head -1)
if [ -z "$mline" ]; then
	# also briefly true during boot (the M.2 mounts in the background)
	raise attention not_mounted
else
	opts=$(echo "$mline" | awk '{print $4}')
	case ",$opts," in *,ro,*) raise failed read_only ;; esac
fi
if [ -r "$EXT4/errors_count" ]; then
	EXT4_ERR=$(num "$(cat "$EXT4/errors_count" 2>/dev/null)")
	[ "$EXT4_ERR" -gt 0 ] && raise attention filesystem_errors
fi

# --- temperature: kernel hwmon (milli-°C) -----------------------------------
for h in "$HWMON"/hwmon*; do
	[ "$(cat "$h/name" 2>/dev/null)" = nvme ] || continue
	t=$(cat "$h/temp1_input" 2>/dev/null); w=$(cat "$h/temp1_max" 2>/dev/null); c=$(cat "$h/temp1_crit" 2>/dev/null)
	[ -n "$t" ] && TEMP_C=$(( $(num "$t") / 1000 ))
	[ -n "$w" ] && WARN_C=$(( $(num "$w") / 1000 ))
	[ -n "$c" ] && CRIT_C=$(( $(num "$c") / 1000 ))
	break
done

# --- SMART / Health log ------------------------------------------------------
SL="$OUT_DIR/disk-smart.json"
if command -v "$NVME" >/dev/null 2>&1 && "$NVME" smart-log "$DEV" -o json >"$SL.$$" 2>/dev/null \
	&& eval "$(jsonfilter -i "$SL.$$" \
		-e 'S_CW=@.critical_warning' -e 'S_TK=@.temperature' -e 'S_SPARE=@.avail_spare' \
		-e 'S_TH=@.spare_thresh' -e 'S_PCT=@.percent_used' -e 'S_MEDIA=@.media_errors' \
		-e 'S_UNSAFE=@.unsafe_shutdowns' -e 'S_POH=@.power_on_hours' -e 'S_DUW=@.data_units_written' \
		-e 'S_WTT=@.warning_temp_time' -e 'S_CTT=@.critical_comp_time' 2>/dev/null)" \
	&& [ -n "${S_CW:-}" ]; then
	mv -f "$SL.$$" "$SL"
	SMART_OK=true
	CW=$(num "$S_CW"); SPARE=$(num "${S_SPARE:-}" 100); THRESH=$(num "${S_TH:-}" 10)
	PCT=$(num "${S_PCT:-}"); MEDIA=$(num "${S_MEDIA:-}"); UNSAFE=$(num "${S_UNSAFE:-}")
	POH=$(num "${S_POH:-}"); WTT=$(num "${S_WTT:-}"); CTT=$(num "${S_CTT:-}")
	# data units are 1000 × 512 bytes
	WRITTEN_GB=$(( $(num "${S_DUW:-}") * 512 / 1000000 ))
	if [ "$TEMP_C" = null ] && [ -n "${S_TK:-}" ] && [ "$(num "$S_TK")" -gt 0 ]; then
		TEMP_C=$(( $(num "$S_TK") - 273 ))
	fi
	# critical_warning bits: 0 spare, 1 temperature, 2 reliability, 3 read-only, 4 backup
	[ $((CW & 8)) -ne 0 ] && raise failed media_read_only
	[ $((CW & 1)) -ne 0 ] && raise at_risk spare_low
	[ $((CW & 4)) -ne 0 ] && raise at_risk reliability_degraded
	[ $((CW & 16)) -ne 0 ] && raise at_risk backup_failed
	[ $((CW & 2)) -ne 0 ] && raise attention temperature_warning
else
	rm -f "$SL.$$"
	raise attention smart_unavailable
fi

# --- per-drive baseline + previous sample (kept on the drive itself, so a
#     factory reset does not hide old errors; /etc fallback if not mounted) ---
if [ -n "$mline" ] && [ -w "$MNT" ]; then BD="$MNT/.disk-health"; else BD="/etc/knots/disk-health"; fi
mkdir -p "$BD" 2>/dev/null || true
key=$(printf '%s' "${SERIAL:-unknown}" | tr -c 'A-Za-z0-9_-' '_')
BASE="$BD/$key.baseline"; PREV="$BD/$key.last"
if [ "$SMART_OK" = true ]; then
	if [ ! -f "$BASE" ]; then
		printf 'media=%s\nspare=%s\nts=%s\n' "$MEDIA" "$SPARE" "$NOW" >"$BASE" 2>/dev/null || true
	fi
	B_MEDIA=$(num "$(sed -n 's/^media=//p' "$BASE" 2>/dev/null)" "$MEDIA")
	B_SPARE=$(num "$(sed -n 's/^spare=//p' "$BASE" 2>/dev/null)" "$SPARE")
	P_UNSAFE=$(num "$(sed -n 's/^unsafe=//p' "$PREV" 2>/dev/null)" "$UNSAFE")
	P_LOSS_TS=$(num "$(sed -n 's/^loss_ts=//p' "$PREV" 2>/dev/null)" 0)
	[ "$UNSAFE" -gt "$P_UNSAFE" ] && P_LOSS_TS=$NOW
	[ "$P_LOSS_TS" -gt 0 ] && [ $((NOW - P_LOSS_TS)) -lt "$POWER_LOSS_NOTICE_SEC" ] && PLOSS=true
	printf 'unsafe=%s\nloss_ts=%s\nts=%s\n' "$UNSAFE" "$P_LOSS_TS" "$NOW" >"$PREV" 2>/dev/null || true

	# spare / wear / media errors (thresholds: PHASE3_STORAGE_RESILIENCE §3)
	if [ "$SPARE" -le "$THRESH" ]; then
		raise at_risk spare_low
	elif [ "$SPARE" -lt $((THRESH + 20)) ] || [ $((B_SPARE - SPARE)) -ge 10 ]; then
		raise attention spare_dropping
	fi
	if [ "$PCT" -ge 100 ]; then raise at_risk wear_out
	elif [ "$PCT" -ge 80 ]; then raise attention wear_high; fi
	if [ "$MEDIA" -ge $((B_MEDIA + 10)) ]; then raise at_risk media_errors
	elif [ "$MEDIA" -gt "$B_MEDIA" ]; then raise attention media_errors; fi

	# hourly history for the wear trend (one line per hour, about a year kept)
	H="$BD/$key.history"
	hr=$((NOW / 3600))
	last=$(tail -1 "$H" 2>/dev/null | cut -d, -f1)
	if [ "$(num "$last")" -lt "$hr" ]; then
		echo "$hr,$TEMP_C,$PCT,$SPARE,$MEDIA,$UNSAFE" >>"$H" 2>/dev/null || true
		n=$(wc -l <"$H" 2>/dev/null || echo 0)
		[ "$(num "$n")" -gt 9000 ] && { tail -8760 "$H" >"$H.t" && mv -f "$H.t" "$H"; } 2>/dev/null
	fi
fi

# --- temperature vs the drive's own limits (fallback 70 / 80 °C) -----------
if [ "$TEMP_C" != null ]; then
	w=$WARN_C; c=$CRIT_C
	[ "$w" = null ] || [ "$w" -le 0 ] && w=70
	[ "$c" = null ] || [ "$c" -le 0 ] && c=80
	if [ "$TEMP_C" -ge "$c" ]; then raise at_risk temperature_critical
	elif [ "$TEMP_C" -ge "$w" ]; then raise attention temperature_warning; fi
fi

emit
