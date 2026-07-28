package main

import "core:strings"
import "core:sync"
import "core:time"

// Token bucket. Refills continuously at `rate` tokens/second up to `burst`.
//
// Used for per-client command, write, broadcast and auth limits. The original
// server had no rate limiting anywhere, which made `wall`, `matrix` and
// `clearall` unlimited global griefing primitives and left login wide open to
// credential stuffing.
Rate_Bucket :: struct {
	tokens: f64,
	rate:   f64,
	burst:  f64,
	last:   time.Time,
}

rate_init :: proc(b: ^Rate_Bucket, rate: f64, burst: f64) {
	b.rate = rate
	b.burst = burst
	b.tokens = burst
	b.last = time.now()
}

// Returns true and consumes a token if one is available.
rate_allow :: proc(b: ^Rate_Bucket) -> bool {
	return rate_allow_n(b, 1)
}

rate_allow_n :: proc(b: ^Rate_Bucket, n: f64) -> bool {
	now := time.now()
	elapsed := time.duration_seconds(time.diff(b.last, now))
	b.last = now

	// A backwards clock step would otherwise credit a huge number of tokens.
	if elapsed > 0 {
		b.tokens = min(b.burst, b.tokens + elapsed * b.rate)
	}

	if b.tokens >= n {
		b.tokens -= n
		return true
	}

	// Counted here rather than at each call site: every bucket in the program
	// funnels through this one refusal, so there is exactly one place to keep
	// correct.
	metric_inc(&g_metrics.rate_limited)
	return false
}

// Seconds until at least one token is available. For user-facing messages.
rate_retry_after :: proc(b: ^Rate_Bucket) -> f64 {
	if b.tokens >= 1 {
		return 0
	}
	if b.rate <= 0 {
		return 0
	}
	return (1 - b.tokens) / b.rate
}

// ---------------------------------------------------------------------------
// Per-IP connection accounting
//
// nginx caps concurrent connections per IP, but the backend must not depend on
// the proxy for its own safety — anything that can reach the socket directly
// bypasses that limit entirely.
// ---------------------------------------------------------------------------

MAX_CONNS_PER_IP :: 8

Conn_Tracker :: struct {
	lock:   sync.Mutex,
	counts: map[string]int,
}

g_conns: Conn_Tracker

conn_tracker_init :: proc(t: ^Conn_Tracker) {
	t.counts = make(map[string]int)
}

// Registers a connection from `ip`. Returns false if that IP is already at its
// limit, in which case nothing is recorded and the caller must not call
// conn_release.
conn_acquire :: proc(t: ^Conn_Tracker, ip: string) -> bool {
	sync.mutex_lock(&t.lock)
	defer sync.mutex_unlock(&t.lock)

	n := t.counts[ip]
	if n >= MAX_CONNS_PER_IP {
		return false
	}

	if n == 0 {
		// The map owns its keys; clone so the entry does not alias a buffer
		// that the caller is about to reuse or free.
		t.counts[strings.clone(ip)] = 1
	} else {
		t.counts[ip] = n + 1
	}
	return true
}

conn_release :: proc(t: ^Conn_Tracker, ip: string) {
	sync.mutex_lock(&t.lock)
	defer sync.mutex_unlock(&t.lock)

	n, ok := t.counts[ip]
	if !ok {
		return
	}
	if n <= 1 {
		// Recover the key allocation as well as the entry, otherwise the map
		// grows without bound across the lifetime of the process.
		key, _ := delete_key(&t.counts, ip)
		delete(key)
	} else {
		t.counts[ip] = n - 1
	}
}
