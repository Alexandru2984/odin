package main

import "core:os"
import "core:strconv"
import "core:time"

// ---------------------------------------------------------------------------
// Network
// ---------------------------------------------------------------------------

PORT :: 47271

// Bind to loopback only. nginx is the sole ingress; the previous 0.0.0.0 bind
// meant the raw, unauthenticated protocol was reachable on the public
// interface and only ufw was keeping it private.
BIND_ADDR :: "127.0.0.1"

// Effective values, resolved once at startup. Overridable from the environment
// so a development instance can run beside the live one without editing
// constants — and so the production defaults stay the safe ones.
g_port: int = PORT
g_bind: string = BIND_ADDR
g_data_dir: string = DATA_DIR

config_load_env :: proc() {
	if v := os.get_env("WEBOS_PORT", context.allocator); len(v) > 0 {
		defer delete(v)
		if n, ok := strconv.parse_int(v); ok && n > 0 && n <= 65535 {
			g_port = n
		}
	}

	// Deliberately not validated against a list: binding is a local decision,
	// and an unparseable address fails loudly at listen() anyway.
	if v := os.get_env("WEBOS_BIND", context.allocator); len(v) > 0 {
		g_bind = v
	}

	if v := os.get_env("WEBOS_DATA_DIR", context.allocator); len(v) > 0 {
		g_data_dir = v
	}
}

// Snapshot paths, derived from the effective data directory.
vfs_snapshot_path :: proc(allocator := context.temp_allocator) -> string {
	return concat_path(g_data_dir, "vfs.db", allocator)
}

user_db_path :: proc(allocator := context.temp_allocator) -> string {
	return concat_path(g_data_dir, "users.db", allocator)
}

// Hard cap on concurrent connections. Each one costs two OS threads (reader +
// writer), so this bounds thread and memory usage. Previously unbounded.
MAX_CLIENTS :: 128

// ---------------------------------------------------------------------------
// Protocol limits
//
// Every one of these exists because the original code had no limit at all and
// read straight into a fixed stack buffer.
// ---------------------------------------------------------------------------

MAX_HTTP_REQUEST :: 16 * 1024 // total request head we will buffer
MAX_HEADER_COUNT :: 64
MAX_WS_MESSAGE   :: 16 * 1024 // reassembled application message
MAX_WS_FRAME     :: 64 * 1024 // single frame payload
MAX_OUT_PENDING  :: 512 * 1024 // per-client queued output before we drop them

// ---------------------------------------------------------------------------
// Timeouts
// ---------------------------------------------------------------------------

// Applied to the socket while reading the HTTP request head. Bounds slowloris:
// a peer that opens a connection and dribbles bytes is dropped.
HANDSHAKE_TIMEOUT :: 15 * time.Second

// recv() timeout during the WebSocket phase. Hitting it is not an error — it
// is how we wake up to send keepalive pings and check the idle deadline.
WS_POLL_TIMEOUT :: 30 * time.Second

// A connection with no traffic at all for this long is closed.
IDLE_TIMEOUT :: 15 * time.Minute

// send() timeout. A peer that stops reading cannot pin a writer thread
// forever.
WRITE_TIMEOUT :: 20 * time.Second

// Unanswered pings before we consider the peer dead.
MAX_MISSED_PONGS :: 3

// ---------------------------------------------------------------------------
// Terminal
// ---------------------------------------------------------------------------

MAX_LINE_LEN    :: 4096 // one command line
MAX_HISTORY     :: 200  // remembered commands per session
MAX_ARGS        :: 64
MAX_OUTPUT_LINES :: 2000 // cap on lines a single command may emit

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

MIN_NAME_LEN :: 2
MAX_NAME_LEN :: 20
MIN_PASSWORD_LEN :: 8
MAX_PASSWORD_LEN :: 128
SESSION_TOKEN_BYTES :: 32

// ---------------------------------------------------------------------------
// VFS quotas
//
// The VFS is shared, in-memory and writable by anonymous users, so every
// dimension of it needs a ceiling or `mkdir` in a loop is an OOM primitive.
// ---------------------------------------------------------------------------

VFS_MAX_ENTRIES     :: 20_000 // total files + directories
VFS_MAX_FILE_SIZE   :: 64 * 1024
VFS_MAX_TOTAL_BYTES :: 32 * 1024 * 1024
VFS_MAX_PATH_LEN    :: 512
VFS_MAX_DEPTH       :: 32
VFS_MAX_NAME_LEN    :: 255
VFS_MAX_PER_USER_ENTRIES :: 2_000

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

DATA_DIR          :: "data"
SNAPSHOT_INTERVAL :: 60 * time.Second

// ---------------------------------------------------------------------------
// Rate limits (token buckets)
// ---------------------------------------------------------------------------

// General command execution.
RATE_CMD_PER_SEC :: 8.0
RATE_CMD_BURST   :: 20.0

// Anything that touches every connected terminal. These were completely
// unlimited and are the obvious griefing primitives.
RATE_BROADCAST_PER_SEC :: 0.2 // one per 5s sustained
RATE_BROADCAST_BURST   :: 3.0

// VFS mutations.
RATE_WRITE_PER_SEC :: 4.0
RATE_WRITE_BURST   :: 15.0

// Login/register attempts, to slow credential stuffing.
RATE_AUTH_PER_SEC :: 0.1 // one per 10s sustained
RATE_AUTH_BURST   :: 5.0

// ---------------------------------------------------------------------------
// Password hashing (Argon2id)
//
// Tuned to stay well inside the service MemoryMax of 512M even with several
// concurrent logins: 64 MiB * 4 concurrent = 256 MiB worst case.
// ---------------------------------------------------------------------------

ARGON2_MEMORY_KIB  :: 64 * 1024
ARGON2_PASSES      :: 3
ARGON2_PARALLELISM :: 1
ARGON2_SALT_BYTES  :: 16
ARGON2_TAG_BYTES   :: 32

// Serialised across all clients so N parallel logins cannot allocate
// N * 64 MiB at once.
MAX_CONCURRENT_HASHES :: 2

// ---------------------------------------------------------------------------
// Origins
//
// Overridable at runtime with WEBOS_ALLOWED_ORIGINS (comma-separated), which is
// what makes a local build testable without editing this table.
// ---------------------------------------------------------------------------

// A global array rather than a constant slice: slicing a constant would
// materialise it in the caller's stack frame and hand back a dangling slice.
@(rodata)
DEFAULT_ALLOWED_ORIGINS := [?]string{"https://odin.micutu.com"}

SERVER_NAME    :: "webos"
SERVER_VERSION :: "2.0.0"
