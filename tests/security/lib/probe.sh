#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Shared TCP probe helpers for zone isolation / stress (T5 / NF10).
# shellcheck disable=SC2034

: "${STRESS_ROUNDS:=3}"
: "${CONNECT_TIMEOUT:=2}"

probe_tcp() {
	# probe_tcp HOST PORT → 0 if connect succeeds
	local host=$1 port=$2
	if command -v nc >/dev/null 2>&1; then
		nc -z -w "$CONNECT_TIMEOUT" "$host" "$port" >/dev/null 2>&1
		return $?
	fi
	# bash /dev/tcp
	timeout "$CONNECT_TIMEOUT" bash -c "echo >/dev/tcp/${host}/${port}" >/dev/null 2>&1
}

expect_closed() {
	local zone=$1 host=$2 port=$3 label=$4
	local i open=0
	for ((i = 1; i <= STRESS_ROUNDS; i++)); do
		if probe_tcp "$host" "$port"; then
			open=1
			break
		fi
	done
	if [ "$open" -eq 0 ]; then
		echo "PASS [$zone] $label ($host:$port) closed (${STRESS_ROUNDS}x)"
		return 0
	fi
	echo "FAIL [$zone] $label ($host:$port) OPEN — must be closed from $zone"
	return 1
}

expect_open() {
	local zone=$1 host=$2 port=$3 label=$4
	local i open=0
	for ((i = 1; i <= STRESS_ROUNDS; i++)); do
		if probe_tcp "$host" "$port"; then
			open=1
			break
		fi
	done
	if [ "$open" -eq 1 ]; then
		echo "PASS [$zone] $label ($host:$port) open"
		return 0
	fi
	echo "FAIL [$zone] $label ($host:$port) closed — expected open from $zone"
	return 1
}

# Extra ports often left open by mistake
EXTRA_CLOSED_PORTS="${EXTRA_CLOSED_PORTS:-21 23 25 53 139 445 3389 5900 8081 8444 9000 9100}"

pass_count=0
fail_count=0

record() {
	if "$@"; then
		pass_count=$((pass_count + 1))
	else
		fail_count=$((fail_count + 1))
	fi
}

summary_exit() {
	echo "=== zone result: pass=$pass_count fail=$fail_count ==="
	[ "$fail_count" -eq 0 ]
}
