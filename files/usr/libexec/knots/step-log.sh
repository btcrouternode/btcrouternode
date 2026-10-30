# SPDX-License-Identifier: GPL-2.0-only
# Timestamped STEP lines for factory reset / firmware apply (serial + logread).
# Usage: knots_step <tag> <message…>

knots_step() {
	_tag=${1:-knots}
	shift
	_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
	_msg="STEP ${_ts} $*"
	logger -t "$_tag" "$_msg" 2>/dev/null || true
	echo "$_msg" >&2
	# Console so USB serial sees the same line without logread.
	if [ -f /etc/openwrt_release ] && [ -c /dev/console ]; then
		echo "$_msg" >/dev/console 2>/dev/null || true
	fi
	# Survive reboot — logread is RAM-only and is empty after sysupgrade.
	case "$_tag" in
		knots-upgrade|knots-progress|knots-pre-reboot)
			mkdir -p /etc/knots
			echo "$_msg" >>/etc/knots/upgrade-last.log 2>/dev/null || true
			;;
	esac
	unset _tag _ts _msg
}
