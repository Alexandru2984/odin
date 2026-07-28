package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

// ---------------------------------------------------------------------------
// Logging
//
// The rewrite removed the original per-connection printf noise, which was the
// right call — it logged an "Endpoint{address = [127, 0, 0, 1], ...}" line for
// every page load and nothing that mattered. But it left the service with no
// record of anything at all: a password-guessing run against every account
// would have been completely invisible.
//
// What is logged here is only what is needed to notice abuse: authentication
// outcomes, rejected handshakes and rate-limit trips. Never a password, never a
// file's contents, never a private message.
//
// Output goes to stdout because the service runs under systemd, which captures
// it into the journal with timestamps and rotation already handled.
// ---------------------------------------------------------------------------

@(private = "file")
g_log_lock: sync.Mutex

// Emitting a line from several connection threads at once would interleave
// them into unparseable soup, so serialise the write.
@(private = "file")
log_line :: proc(level: string, event: string, fields: string) {
	now := time.now()
	y, mo, d := time.date(now)
	h, mi, s := time.clock_from_time(now)

	sync.mutex_lock(&g_log_lock)
	defer sync.mutex_unlock(&g_log_lock)

	fmt.printfln(
		"%04d-%02d-%02dT%02d:%02d:%02dZ %s %s %s",
		y,
		int(mo),
		d,
		h,
		mi,
		s,
		level,
		event,
		fields,
	)
}

// Values reach the log from the network, so they are stripped of anything that
// could forge a log line — a newline would let a username inject a fabricated
// entry, and an escape sequence would rewrite the terminal of whoever is
// tailing the journal.
@(private = "file")
log_value :: proc(s: string) -> string {
	return sanitize_text(s, 64, context.temp_allocator)
}

// An authentication or account event. `subject` is a username, never a secret.
log_security :: proc(event: string, c: ^Client, subject: string, success: bool) {
	metric_inc(&g_metrics.auth_attempts)
	if !success {
		metric_inc(&g_metrics.auth_failures)
	}

	outcome := success ? "ok" : "denied"
	log_line(
		"AUTH",
		event,
		fmt.tprintf(
			"outcome=%s user=%q ip=%q session=%d",
			outcome,
			log_value(subject),
			log_value(c.ip),
			c.id,
		),
	)
}

// A request refused before it became a session: a bad origin, an oversized
// head, too many connections from one address.
log_reject :: proc(reason: string, ip: string, detail: string = "") {
	metric_inc(&g_metrics.connections_refused)

	if len(detail) > 0 {
		log_line("REJECT", reason, fmt.tprintf("ip=%q detail=%q", log_value(ip), log_value(detail)))
		return
	}
	log_line("REJECT", reason, fmt.tprintf("ip=%q", log_value(ip)))
}

log_info :: proc(event: string, detail: string) {
	log_line("INFO", event, detail)
}

// ---------------------------------------------------------------------------
// Abuse counters
//
// A single rejected request is noise; a thousand from one address is an attack.
// Logging every one would itself be the denial of service, so they are counted
// and reported at most once a minute per reason.
// ---------------------------------------------------------------------------

@(private = "file")
Abuse_Counter :: struct {
	count:    int,
	reported: time.Time,
}

@(private = "file")
g_abuse: map[string]Abuse_Counter

@(private = "file")
g_abuse_lock: sync.Mutex

ABUSE_REPORT_INTERVAL :: 60 * time.Second

abuse_init :: proc() {
	g_abuse = make(map[string]Abuse_Counter)
}

// Records one occurrence, and logs a summary if the reporting interval has
// elapsed. `reason` must be one of a fixed set of literals, so the map cannot
// be grown without bound by a remote peer.
log_abuse :: proc(reason: string, ip: string) {
	should_report := false
	total := 0

	sync.mutex_lock(&g_abuse_lock)
	entry, found := g_abuse[reason]
	if !found {
		entry = Abuse_Counter {
			reported = time.now(),
		}
	}
	entry.count += 1

	if time.diff(entry.reported, time.now()) >= ABUSE_REPORT_INTERVAL {
		should_report = true
		total = entry.count
		entry.count = 0
		entry.reported = time.now()
	}
	g_abuse[reason] = entry
	sync.mutex_unlock(&g_abuse_lock)

	if should_report {
		log_line("ABUSE", reason, fmt.tprintf("count=%d window=60s last_ip=%q", total, log_value(ip)))
	}
}

// Renders the current counters for the `dmesg` command.
abuse_summary :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)

	sync.mutex_lock(&g_abuse_lock)
	defer sync.mutex_unlock(&g_abuse_lock)

	if len(g_abuse) == 0 {
		strings.write_string(&b, "no rejections recorded in the current window\n")
		return strings.to_string(b)
	}

	for reason, entry in g_abuse {
		fmt.sbprintf(&b, "  %-24s %d in the current window\n", reason, entry.count)
	}
	return strings.to_string(b)
}
