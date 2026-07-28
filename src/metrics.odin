package main

import "base:intrinsics"
import "core:fmt"
import "core:strings"
import "core:time"

// ---------------------------------------------------------------------------
// Metrics
//
// The host already runs Prometheus and Grafana for other services, and this
// one was the only thing on it with no visibility at all: whether anyone was
// connected, how much of the filesystem quota was gone, and whether the rate
// limiters were doing anything could only be answered by logging in and
// looking.
//
// Counters are plain integers incremented with atomics rather than guarded by
// a mutex. They are written on every connection and every command, from every
// thread, and a lock on that path would be a contention point introduced
// purely for observability. A counter that is momentarily stale is fine; one
// that costs throughput is not.
// ---------------------------------------------------------------------------

Metrics :: struct {
	connections_total:   int, // accepted WebSocket sessions
	connections_refused: int, // rejected before a session existed
	commands_total:      int, // command lines run
	commands_failed:     int, // command lines that ended non-zero
	auth_attempts:       int,
	auth_failures:       int,
	rate_limited:        int, // any bucket refusing an action
	broadcasts_total:    int,
	jobs_started:        int,
	scripts_run:         int,
	interrupts:          int, // ^C that actually reached a command
	bytes_sent:          int,
	bytes_received:      int,
	output_dropped:      int, // clients dropped for not draining
}

g_metrics: Metrics

// The one counter that needs a name at the call site rather than a field:
// every rejection reason is worth telling apart in a dashboard, and a map
// would need a lock.
metric_inc :: proc(counter: ^int) {
	intrinsics.atomic_add(counter, 1)
}

metric_add :: proc(counter: ^int, n: int) {
	intrinsics.atomic_add(counter, n)
}

@(private = "file")
metric_get :: proc(counter: ^int) -> int {
	return intrinsics.atomic_load(counter)
}

// ---------------------------------------------------------------------------
// Exposition
// ---------------------------------------------------------------------------

@(private = "file")
counter :: proc(b: ^strings.Builder, name: string, help: string, value: int) {
	fmt.sbprintf(b, "# HELP webos_%s %s\n", name, help)
	fmt.sbprintf(b, "# TYPE webos_%s counter\n", name)
	fmt.sbprintf(b, "webos_%s %d\n", name, value)
}

@(private = "file")
gauge :: proc(b: ^strings.Builder, name: string, help: string, value: int) {
	fmt.sbprintf(b, "# HELP webos_%s %s\n", name, help)
	fmt.sbprintf(b, "# TYPE webos_%s gauge\n", name)
	fmt.sbprintf(b, "webos_%s %d\n", name, value)
}

// Renders the whole exposition in Prometheus' text format.
//
// Nothing here identifies a user. Counts and totals answer "is it healthy and
// how busy is it"; names, addresses and paths would answer "who is on it and
// what are they doing", which is not a monitoring question.
metrics_render :: proc(allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)

	uptime := int(time.duration_seconds(time.since(g_started_at)))
	gauge(&b, "uptime_seconds", "Seconds since the server started.", uptime)

	// --- Sessions ---
	gauge(&b, "sessions", "Sessions currently connected.", client_count())
	gauge(&b, "sessions_max", "Hard cap on concurrent sessions.", MAX_CLIENTS)
	counter(
		&b,
		"connections_total",
		"WebSocket sessions accepted since start.",
		metric_get(&g_metrics.connections_total),
	)
	counter(
		&b,
		"connections_refused_total",
		"Connections rejected before a session existed.",
		metric_get(&g_metrics.connections_refused),
	)

	// --- Work ---
	counter(
		&b,
		"commands_total",
		"Command lines executed. A line joined by ; or && counts once.",
		metric_get(&g_metrics.commands_total),
	)
	counter(
		&b,
		"commands_failed_total",
		"Command lines whose last pipeline ended with a non-zero status.",
		metric_get(&g_metrics.commands_failed),
	)
	counter(
		&b,
		"scripts_run_total",
		"Scripts started with sh.",
		metric_get(&g_metrics.scripts_run),
	)
	counter(
		&b,
		"jobs_started_total",
		"Background jobs started with &.",
		metric_get(&g_metrics.jobs_started),
	)
	counter(
		&b,
		"interrupts_total",
		"Interrupts that reached a running command.",
		metric_get(&g_metrics.interrupts),
	)

	running, total_procs := proc_counts()
	gauge(&b, "processes_running", "Processes currently running.", running)
	gauge(&b, "processes_tracked", "Entries in the process table, including finished ones.", total_procs)

	// --- Identity ---
	counter(
		&b,
		"auth_attempts_total",
		"Login and registration attempts.",
		metric_get(&g_metrics.auth_attempts),
	)
	counter(
		&b,
		"auth_failures_total",
		"Attempts that were refused.",
		metric_get(&g_metrics.auth_failures),
	)
	gauge(&b, "accounts", "Registered accounts.", auth_count(&g_users))

	// --- Abuse ---
	counter(
		&b,
		"rate_limited_total",
		"Actions refused by a rate limiter.",
		metric_get(&g_metrics.rate_limited),
	)
	counter(
		&b,
		"broadcasts_total",
		"Messages sent to every connected terminal.",
		metric_get(&g_metrics.broadcasts_total),
	)
	counter(
		&b,
		"output_dropped_total",
		"Sessions dropped for not draining their output.",
		metric_get(&g_metrics.output_dropped),
	)

	// --- Filesystem ---
	usage := vfs_usage(&g_vfs)
	gauge(&b, "vfs_entries", "Files and directories in the filesystem.", usage.entries)
	gauge(&b, "vfs_entries_max", "Cap on files and directories.", usage.max_entries)
	gauge(&b, "vfs_bytes", "Bytes stored in the filesystem.", usage.total_bytes)
	gauge(&b, "vfs_bytes_max", "Cap on stored bytes.", usage.max_bytes)

	// --- Traffic ---
	counter(&b, "bytes_sent_total", "Bytes written to clients.", metric_get(&g_metrics.bytes_sent))
	counter(
		&b,
		"bytes_received_total",
		"Bytes read from clients.",
		metric_get(&g_metrics.bytes_received),
	)

	return strings.to_string(b)
}
