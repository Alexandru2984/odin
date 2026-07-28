#!/usr/bin/env bash
#
# Integration tests.
#
# These drive a real WebSocket client against a real server, so they cover what
# the unit tests structurally cannot: the framing, the connection lifecycle, the
# VFS as several sessions see it at once, and every command end to end.
#
# A private instance is started on its own port with its own data directory and
# torn down afterwards, so running this never touches the live service or its
# snapshots. Each suite gets a clean server: the accounts and files they create
# use fixed names, and a second run against the same state would collide with
# the first.
#
#   ./tests/run.sh            all suites
#   ./tests/run.sh shell      one suite, by the middle part of its file name
#
set -uo pipefail

cd "$(dirname "$0")/.."

PORT="${WEBOS_TEST_PORT:-47999}"
BIN=bin/webos_server
WORK="$(mktemp -d)"
SERVER_PID=""

cleanup() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT

if [ ! -x "$BIN" ]; then
	echo "no $BIN — run 'make build' first" >&2
	exit 1
fi

PY="${PYTHON:-python3}"
if ! "$PY" -c 'import sys' 2>/dev/null; then
	echo "python3 is required" >&2
	exit 1
fi

start_server() {
	rm -rf "$WORK/data"
	mkdir -p "$WORK/data"
	WEBOS_PORT="$PORT" WEBOS_BIND=127.0.0.1 WEBOS_DATA_DIR="$WORK/data" \
		"$BIN" >"$WORK/server.log" 2>&1 &
	SERVER_PID=$!

	# Wait for the listener rather than sleeping a guessed amount.
	for _ in $(seq 1 50); do
		if curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.1
	done

	echo "server did not come up on port $PORT" >&2
	cat "$WORK/server.log" >&2
	return 1
}

stop_server() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
	SERVER_PID=""
}

filter="${1:-}"
failed=()
ran=0

for suite in tests/test_*.py; do
	name="$(basename "$suite" .py)"
	name="${name#test_}"
	if [ -n "$filter" ] && [ "$name" != "$filter" ]; then
		continue
	fi

	start_server || exit 1
	printf '%-12s ' "$name"

	if PORT="$PORT" PYTHONPATH=tests "$PY" "$suite" >"$WORK/$name.out" 2>&1; then
		echo "ok"
	else
		echo "FAILED"
		failed+=("$name")
		sed 's/^/    /' "$WORK/$name.out"
	fi

	ran=$((ran + 1))
	stop_server
done

if [ "$ran" -eq 0 ]; then
	echo "no suite matched '$filter'" >&2
	exit 1
fi

echo
if [ "${#failed[@]}" -gt 0 ]; then
	echo "${#failed[@]} of $ran suites failed: ${failed[*]}"
	exit 1
fi
echo "$ran suites passed"
