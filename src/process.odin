package main

import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// ---------------------------------------------------------------------------
// Processes
//
// `ps` used to list connections and call them processes. Nothing was actually
// tracked: a command ran to completion on the reader thread and left no trace,
// so there was nothing to see, nothing to wait for and nothing to kill.
//
// A process here is one pipeline being run on behalf of one session. Every
// pipeline gets an entry, foreground or not, which is what makes `ps` show what
// the machine is really doing rather than who is connected.
//
// `cmd &` runs the pipeline on its own thread. That thread must not touch
// session state — cwd, variables, aliases, the editor — because the reader
// thread owns all of it without a lock. It gets a snapshot instead, which is
// also the correct semantics: a background job is a subshell, and a subshell's
// `cd` has never affected its parent.
// ---------------------------------------------------------------------------

// Background jobs per session. Each costs a thread, so this is a thread bound
// as much as a usability one: MAX_CLIENTS * MAX_JOBS_PER_SESSION is the worst
// case the process has to survive.
MAX_JOBS_PER_SESSION :: 4

// Total live background jobs across every session.
MAX_BACKGROUND_JOBS :: 32

// How long a finished job stays in the table so `jobs` can report it before it
// is reaped.
JOB_LINGER :: 60 * time.Second

Process_State :: enum {
	Running,
	Done,
	Killed,
}

process_state_string :: proc(s: Process_State) -> string {
	switch s {
	case .Running:
		return "running"
	case .Done:
		return "done"
	case .Killed:
		return "killed"
	}
	return "?"
}

Process :: struct {
	pid:        int,
	session:    int, // client id that owns it
	owner:      string, // owned; name at spawn time
	command:    string, // owned; already sanitized for display
	started:    i64,
	finished:   i64,
	background: bool,

	// Written by the owning thread, read by everyone through the table lock.
	state:      Process_State,
	status:     int,

	// Set by `kill` or by the session going away. The running command polls it
	// through proc_cancelled; nothing is preempted, so a command that never
	// looks at it simply runs to completion.
	cancel:     bool,
}

// What a detached job carries instead of reaching into the live session.
Detached :: struct {
	pid:  int,
	cwd:  string,
	user: string,
}

@(private = "file")
g_procs_lock: sync.Mutex

@(private = "file")
g_procs: [dynamic]^Process

@(private = "file")
g_next_pid: int = 1

@(private = "file")
g_background_count: int

// The table lock is a leaf: no other lock may be taken while it is held. That
// is the whole ordering rule for it, and it is why every procedure here copies
// what it needs and releases before printing or sending anything.

proc_table_init :: proc() {
	g_procs = make([dynamic]^Process)
}

proc_table_destroy :: proc() {
	sync.mutex_lock(&g_procs_lock)
	defer sync.mutex_unlock(&g_procs_lock)

	for p in g_procs {
		delete(p.owner)
		delete(p.command)
		free(p)
	}
	delete(g_procs)
}

// Registers a pipeline and returns its pid.
proc_begin :: proc(session: int, owner: string, command: string, background: bool) -> int {
	p := new(Process)
	p.session = session
	p.owner = strings.clone(owner)
	p.command = strings.clone(command)
	p.started = time.time_to_unix(time.now())
	p.state = .Running
	p.background = background

	sync.mutex_lock(&g_procs_lock)
	defer sync.mutex_unlock(&g_procs_lock)

	p.pid = g_next_pid
	g_next_pid += 1
	if background {
		g_background_count += 1
	}
	append(&g_procs, p)

	reap_locked()
	return p.pid
}

// Marks a pipeline finished. A killed process keeps that state: it says
// something the exit status does not.
proc_end :: proc(pid: int, status: int) {
	sync.mutex_lock(&g_procs_lock)
	defer sync.mutex_unlock(&g_procs_lock)

	for p in g_procs {
		if p.pid != pid {
			continue
		}
		if p.state == .Running {
			p.state = .Done
		}
		p.status = status
		p.finished = time.time_to_unix(time.now())
		if p.background {
			g_background_count -= 1
		}
		return
	}
}

// Whether the command running as `pid` has been asked to stop.
//
// pid 0 means "not running as a tracked process", which is the case for the
// interactive paths that build a context by hand.
proc_cancelled :: proc(pid: int) -> bool {
	if pid == 0 {
		return false
	}

	sync.mutex_lock(&g_procs_lock)
	defer sync.mutex_unlock(&g_procs_lock)

	for p in g_procs {
		if p.pid == pid {
			return p.cancel
		}
	}
	return false
}

// Asks a process to stop. Only its owner may.
proc_kill :: proc(pid: int, session: int) -> (found: bool, allowed: bool) {
	sync.mutex_lock(&g_procs_lock)
	defer sync.mutex_unlock(&g_procs_lock)

	for p in g_procs {
		if p.pid != pid {
			continue
		}
		if p.session != session {
			return true, false
		}
		if p.state == .Running {
			p.cancel = true
			p.state = .Killed
		}
		return true, true
	}
	return false, false
}

// Stops everything a session owns. Called when the session goes away, so a
// disconnected user's background work does not keep running against a client
// that no longer exists.
proc_kill_session :: proc(session: int) {
	sync.mutex_lock(&g_procs_lock)
	defer sync.mutex_unlock(&g_procs_lock)

	for p in g_procs {
		if p.session == session && p.state == .Running {
			p.cancel = true
			// Marked here rather than left for proc_end, which only promotes a
			// Running process to Done: without this the table would report a
			// job that was cut short as having finished normally.
			p.state = .Killed
		}
	}
}

// A copy of the table for `ps` and `jobs`. The caller owns the result; strings
// are cloned because the entries behind them can be reaped at any moment.
proc_snapshot :: proc(session: int, only_own: bool, allocator := context.temp_allocator) -> []Process {
	sync.mutex_lock(&g_procs_lock)
	defer sync.mutex_unlock(&g_procs_lock)

	out := make([dynamic]Process, allocator)
	for p in g_procs {
		if only_own && p.session != session {
			continue
		}
		copy := p^
		copy.owner = strings.clone(p.owner, allocator)
		copy.command = strings.clone(p.command, allocator)
		append(&out, copy)
	}
	return out[:]
}

// True while the given process is still running.
proc_is_running :: proc(pid: int) -> bool {
	sync.mutex_lock(&g_procs_lock)
	defer sync.mutex_unlock(&g_procs_lock)

	for p in g_procs {
		if p.pid == pid {
			return p.state == .Running
		}
	}
	return false
}

// Drops finished entries that nobody is going to ask about again. Called with
// the lock held, from proc_begin, so the table cannot grow without bound over
// a long-lived process.
@(private = "file")
reap_locked :: proc() {
	now := time.time_to_unix(time.now())
	linger := i64(JOB_LINGER / time.Second)

	i := 0
	for i < len(g_procs) {
		p := g_procs[i]
		expired := p.state != .Running && p.finished > 0 && now - p.finished > linger
		if !expired {
			i += 1
			continue
		}
		delete(p.owner)
		delete(p.command)
		free(p)
		ordered_remove(&g_procs, i)
	}
}

// ---------------------------------------------------------------------------
// Running a pipeline in the background
// ---------------------------------------------------------------------------

// Everything the worker thread needs. Heap-allocated and owned by the thread,
// because the reader thread's temp allocator is reset the moment it returns to
// reading.
@(private = "file")
Job :: struct {
	client: ^Client,
	pid:    int,
	line:   string, // owned
	cwd:    string, // owned
	user:   string, // owned
}

// Starts `line` on its own thread. Returns the pid, or 0 if the job was
// refused.
proc_spawn :: proc(c: ^Client, line: string) -> (pid: int, err: string) {
	// Two ceilings: one so a single session cannot occupy every thread, one so
	// all sessions together cannot.
	own := proc_snapshot(c.id, true, context.temp_allocator)
	running := 0
	for p in own {
		if p.background && p.state == .Running {
			running += 1
		}
	}
	if running >= MAX_JOBS_PER_SESSION {
		return 0, "too many background jobs in this session"
	}

	sync.mutex_lock(&g_procs_lock)
	total := g_background_count
	sync.mutex_unlock(&g_procs_lock)
	if total >= MAX_BACKGROUND_JOBS {
		return 0, "the server is already running as many background jobs as it will"
	}

	display := sanitize_text(line, 80, context.temp_allocator)
	new_pid := proc_begin(c.id, client_get_name(c, context.temp_allocator), display, true)

	// The job outlives the reader thread's view of the session, so it takes
	// its own reference and drops it when the thread ends.
	client_ref(c)

	job := new(Job)
	job.client = c
	job.pid = new_pid
	job.line = strings.clone(line)
	job.cwd = client_get_cwd(c, context.allocator)
	job.user = client_get_user(c, context.allocator)

	// self_cleanup, like the connection threads: nothing joins a background job,
	// so the Thread has to release itself when its procedure returns.
	t := thread.create_and_start_with_data(job, job_thread, self_cleanup = true)
	if t == nil {
		proc_end(new_pid, 1)
		client_unref(job.client)
		job_destroy(job)
		return 0, "could not start a thread for the job"
	}

	return new_pid, ""
}

@(private = "file")
job_destroy :: proc(job: ^Job) {
	delete(job.line)
	delete(job.cwd)
	delete(job.user)
	free(job)
}

@(private = "file")
job_thread :: proc(raw: rawptr) {
	job := (^Job)(raw)
	client := job.client
	defer client_unref(client) // runs last: everything below still uses it
	defer job_destroy(job)

	detached := Detached {
		pid  = job.pid,
		cwd  = job.cwd,
		user = job.user,
	}

	status := shell_run_detached(job.client, job.line, &detached)
	proc_end(job.pid, status)

	// Announce completion the way a shell does, so a job that finishes while
	// the user is doing something else does not just silently stop. A killed
	// job says nothing — `kill` already reported it.
	if !proc_cancelled(job.pid) {
		client_sendf(
			job.client,
			"\r\n\x1b[90m[%d] done: %s\x1b[0m\r\n",
			job.pid,
			sanitize_text(job.line, 60, context.temp_allocator),
		)
	}

	// The prompt is redrawn either way. Whatever the job printed landed on top
	// of whatever the user was looking at, and without this its last line and
	// the prompt share a row — which is exactly what a killed job looked like,
	// since it took the early return and never redrew.
	client_send_prompt(job.client)

	free_all(context.temp_allocator)
}
