package main

import "core:strings"
import "core:time"

// ---------------------------------------------------------------------------
// Process commands
// ---------------------------------------------------------------------------

// Commands that change the session rather than the filesystem. A background
// job runs on its own thread against a snapshot, so letting one of these run
// there would either be a data race on state the reader thread owns without a
// lock, or a silent no-op once the job exited — both worse than refusing.
//
// This is also how a real shell behaves: a subshell's `cd` does not move its
// parent, and nobody expects `cd /tmp &` to do anything.
@(rodata)
SESSION_COMMANDS := [?]string {
	"cd",
	"export",
	"unset",
	"alias",
	"unalias",
	"login",
	"logout",
	"register",
	"passwd",
	"name",
	"color",
	"theme",
	"edit",
	"less",
	"clear",
	"history",
	"su",
}

is_session_command :: proc(name: string) -> bool {
	for s in SESSION_COMMANDS {
		if s == name {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------

cmd_ps :: proc(ctx: ^Cmd_Ctx, args: []string) {
	all := false
	for a in args {
		if a == "-a" || a == "-e" {
			all = true
		}
	}

	// Own processes by default; everyone's with -a, which is the interesting
	// view on a machine several people are sharing.
	procs := proc_snapshot(ctx.client.id, !all, context.temp_allocator)

	if ctx_is_narrow(ctx) {
		outf(ctx, "\x1b[1m%-6s %-9s %s\x1b[0m\n", "PID", "STATE", "COMMAND")
		for p in procs {
			outf(
				ctx,
				"%s %-9s %s\n",
				pad_int_left(p.pid, 6),
				process_state_string(p.state),
				truncate_runes(p.command, 24, context.temp_allocator),
			)
		}
		return
	}

	outf(
		ctx,
		"\x1b[1m%-6s %-14s %-9s %-6s %s\x1b[0m\n",
		"PID",
		"USER",
		"STATE",
		"TIME",
		"COMMAND",
	)

	now := time.time_to_unix(time.now())
	for p in procs {
		until := p.state == .Running ? now : p.finished
		elapsed := until - p.started
		if elapsed < 0 {
			elapsed = 0
		}
		outf(
			ctx,
			"%s %-14s %-9s %-6s %s%s\n",
			pad_int_left(p.pid, 6),
			truncate_runes(p.owner, 14, context.temp_allocator),
			process_state_string(p.state),
			duration_short(int(elapsed), context.temp_allocator),
			p.background ? "" : "",
			truncate_runes(p.command, 40, context.temp_allocator),
		)
	}

	if len(procs) == 0 {
		out(ctx, "no processes\n")
	}
}

cmd_jobs :: proc(ctx: ^Cmd_Ctx, args: []string) {
	procs := proc_snapshot(ctx.client.id, true, context.temp_allocator)

	shown := 0
	for p in procs {
		if !p.background {
			continue
		}
		shown += 1
		colour := p.state == .Running ? "\x1b[32m" : "\x1b[90m"
		outf(
			ctx,
			"[%d]  %s%-8s\x1b[0m %s\n",
			p.pid,
			colour,
			process_state_string(p.state),
			truncate_runes(p.command, 50, context.temp_allocator),
		)
	}

	if shown == 0 {
		out(ctx, "no background jobs\n")
		out(ctx, "  end a command with \x1b[36m&\x1b[0m to run it in the background\n")
	}
}

cmd_kill :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		errf(ctx, "kill: usage: kill <pid...>\n")
		out(ctx, "  \x1b[36mjobs\x1b[0m lists your background jobs and their pids\n")
		return
	}

	for a in args {
		pid, ok := parse_positive_int(unquote(a))
		if !ok {
			errf(ctx, "kill: %s: not a pid\n", sanitize_text(a, 16, context.temp_allocator))
			continue
		}

		found, allowed := proc_kill(pid, ctx.client.id)
		switch {
		case !found:
			errf(ctx, "kill: %d: no such process\n", pid)
		case !allowed:
			// Naming the owner would leak who is doing what; the refusal is
			// enough.
			errf(ctx, "kill: %d: not your process\n", pid)
		case:
			outf(ctx, "[%d] killed\n", pid)
		}
	}
}

// Waits for background jobs to finish.
//
// The wait is a poll rather than a condition variable: a job signalling
// completion would have to reach across to whichever thread happens to be
// waiting, and this runs on the reader thread where a spurious extra second
// costs nothing.
cmd_wait :: proc(ctx: ^Cmd_Ctx, args: []string) {
	MAX_WAIT :: 60 * time.Second
	POLL :: 100 * time.Millisecond

	targets := make([dynamic]int, context.temp_allocator)
	for a in args {
		pid, ok := parse_positive_int(unquote(a))
		if !ok {
			errf(ctx, "wait: %s: not a pid\n", sanitize_text(a, 16, context.temp_allocator))
			return
		}
		append(&targets, pid)
	}

	// No argument waits for everything this session started.
	if len(targets) == 0 {
		for p in proc_snapshot(ctx.client.id, true, context.temp_allocator) {
			if p.background && p.state == .Running {
				append(&targets, p.pid)
			}
		}
	}
	if len(targets) == 0 {
		out(ctx, "nothing to wait for\n")
		return
	}

	deadline := time.time_add(time.now(), MAX_WAIT)
	for {
		remaining := 0
		for pid in targets {
			if proc_is_running(pid) {
				remaining += 1
			}
		}
		if remaining == 0 {
			outf(ctx, "%d job(s) finished\n", len(targets))
			return
		}
		if time.since(deadline) >= 0 {
			errf(ctx, "wait: still running after %v\n", MAX_WAIT)
			return
		}
		time.sleep(POLL)
	}
}

// Sleeps, in whole seconds, checking for cancellation as it goes.
//
// It exists to make the rest of this file usable: a process model needs
// something that takes long enough to observe, background, list and kill.
cmd_sleep :: proc(ctx: ^Cmd_Ctx, args: []string) {
	MAX_SLEEP :: 300

	if len(args) == 0 {
		errf(ctx, "sleep: usage: sleep <seconds>\n")
		return
	}

	seconds, ok := parse_positive_int(unquote(args[0]))
	if !ok {
		errf(ctx, "sleep: %s: not a number of seconds\n",
			sanitize_text(args[0], 16, context.temp_allocator))
		return
	}
	if seconds > MAX_SLEEP {
		errf(ctx, "sleep: at most %d seconds\n", MAX_SLEEP)
		return
	}

	// Woken every 100ms rather than once, so `kill` and a disconnect take
	// effect promptly instead of after the full duration.
	ticks := seconds * 10
	for _ in 0 ..< ticks {
		if proc_cancelled(ctx.proc_id) {
			errf(ctx, "sleep: interrupted\n")
			return
		}
		time.sleep(100 * time.Millisecond)
	}
}

// ---------------------------------------------------------------------------

// "1h02m", "3m07s", "12s" — narrow enough for a column.
duration_short :: proc(seconds: int, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	switch {
	case seconds >= 3600:
		strings.write_int(&b, seconds / 3600)
		strings.write_string(&b, "h")
		strings.write_string(&b, pad_int_zero((seconds % 3600) / 60, 2, allocator))
		strings.write_string(&b, "m")
	case seconds >= 60:
		strings.write_int(&b, seconds / 60)
		strings.write_string(&b, "m")
		strings.write_string(&b, pad_int_zero(seconds % 60, 2, allocator))
		strings.write_string(&b, "s")
	case:
		strings.write_int(&b, seconds)
		strings.write_string(&b, "s")
	}
	return strings.to_string(b)
}
