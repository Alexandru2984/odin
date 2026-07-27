package main

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

g_vfs: VFS
g_users: User_DB

g_clients:      [dynamic]^Client
g_clients_lock: sync.Mutex

g_next_id:      int
g_id_lock:      sync.Mutex

// Total in-flight connection handler threads, including ones still deciding
// whether they are a page load or a terminal session.
g_handlers:      int
g_handlers_lock: sync.Mutex

g_started_at: time.Time

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

main :: proc() {
	g_started_at = time.now()
	config_load_env()
	install_signal_handlers()

	vfs_init(&g_vfs)
	auth_init(&g_users)
	conn_tracker_init(&g_conns)
	abuse_init()
	g_clients = make([dynamic]^Client)

	// Restore the previous session's state, if any.
	persist_load()

	endpoint, parse_ok := net.parse_endpoint(fmt.tprintf("%s:%d", g_bind, g_port))
	if !parse_ok {
		fmt.eprintln("fatal: could not parse bind endpoint")
		os.exit(1)
	}

	server, listen_err := net.listen_tcp(endpoint)
	if listen_err != nil {
		fmt.eprintfln("fatal: listen on %s:%d failed: %v", g_bind, g_port, listen_err)
		os.exit(1)
	}
	defer net.close(server)

	// Background snapshotter: bounds how much state a crash or redeploy can
	// lose without needing a signal handler.
	thread.create_and_start(persist_worker, self_cleanup = true)

	fmt.printfln(
		"%s %s listening on %s:%d (max %d clients)",
		SERVER_NAME,
		SERVER_VERSION,
		g_bind,
		g_port,
		MAX_CLIENTS,
	)

	for {
		client_socket, peer, accept_err := net.accept_tcp(server)
		if accept_err != nil {
			// A transient accept failure must not kill the listener.
			continue
		}

		if !handler_acquire() {
			// Over capacity: reply honestly and close rather than queueing up
			// threads we cannot afford.
			http_send_status(client_socket, 503, "Service Unavailable")
			net.close(client_socket)
			continue
		}

		pending := new(Pending_Conn)
		pending.socket = client_socket
		pending.peer = peer

		thread.create_and_start_with_data(pending, connection_proc, self_cleanup = true)
	}
}

Pending_Conn :: struct {
	socket: net.TCP_Socket,
	peer:   net.Endpoint,
}

// ---------------------------------------------------------------------------
// Capacity accounting
// ---------------------------------------------------------------------------

handler_acquire :: proc() -> bool {
	sync.mutex_lock(&g_handlers_lock)
	defer sync.mutex_unlock(&g_handlers_lock)

	// Headroom above MAX_CLIENTS so that plain page loads are still served
	// when the terminal session slots are full.
	if g_handlers >= MAX_CLIENTS + 64 {
		return false
	}
	g_handlers += 1
	return true
}

handler_release :: proc() {
	sync.mutex_lock(&g_handlers_lock)
	defer sync.mutex_unlock(&g_handlers_lock)
	g_handlers -= 1
}

next_client_id :: proc() -> int {
	sync.mutex_lock(&g_id_lock)
	defer sync.mutex_unlock(&g_id_lock)
	g_next_id += 1
	return g_next_id
}

client_count :: proc() -> int {
	sync.mutex_lock(&g_clients_lock)
	defer sync.mutex_unlock(&g_clients_lock)
	return len(g_clients)
}

// ---------------------------------------------------------------------------
// Connection handling
// ---------------------------------------------------------------------------

connection_proc :: proc(data: rawptr) {
	pending := cast(^Pending_Conn)data

	// Each thread gets its own thread-local temp allocator arena, and nothing
	// ever released it. With one thread per connection and 38k connections
	// served, that alone accounted for most of the 719 MB the service had
	// grown to. Destroying it here returns the arena at thread exit; the
	// terminal loop additionally calls free_all once per command.
	defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)

	defer handler_release()
	defer free(pending)
	defer net.close(pending.socket)

	handle_connection(pending.socket, pending.peer)
}

handle_connection :: proc(socket: net.TCP_Socket, peer: net.Endpoint) {
	net.set_option(socket, .TCP_Nodelay, true)

	raw := make([dynamic]byte, 0, 4096)
	defer delete(raw)

	req, ok := http_read_request(socket, &raw)
	if !ok {
		return
	}
	defer http_request_destroy(&req)

	head_only := req.method == "HEAD"
	if req.method != "GET" && !head_only {
		http_send_status(socket, 405, "Method Not Allowed")
		return
	}

	// Strip any query string before routing.
	route := req.target
	if q := strings.index_byte(route, '?'); q >= 0 {
		route = route[:q]
	}

	if route == "/ws" {
		handle_ws_request(socket, peer, &req)
		return
	}

	if route == "/healthz" {
		// Deliberately says nothing about who is connected or how busy the
		// service is: this endpoint is reachable from the internet, and session
		// counts are free reconnaissance for anyone deciding whether an attack
		// is working.
		http_send_response(
			socket,
			200,
			"OK",
			"text/plain; charset=utf-8",
			transmute([]byte)string("ok\n"),
			head_only = head_only,
		)
		return
	}

	http_serve_static(socket, req.target, head_only)
}

// Determines the real client address.
//
// Proxy headers are believed only when the connection genuinely arrived from
// loopback, which is the only place nginx can be.
//
// Trusting them unconditionally is a rate-limit bypass: every limit in the
// server — per-IP connection count, and by extension the auth and broadcast
// budgets attached to a session — is keyed on this string. Anything able to
// reach the socket directly could send `X-Real-IP: <anything>` and have the
// limits applied to an address it invented, spending a fresh budget on every
// connection while the real source was never counted. Binding to loopback
// makes that unreachable today; this makes it safe regardless.
client_address :: proc(peer: net.Endpoint, req: ^HTTP_Request) -> string {
	direct := net.address_to_string(peer.address, context.temp_allocator)

	if !is_loopback_address(peer.address) {
		return direct
	}

	if xri := http_header(req, "x-real-ip"); is_plausible_address(xri) {
		return strings.clone(xri, context.temp_allocator)
	}
	if xff := http_header(req, "x-forwarded-for"); len(xff) > 0 {
		// Left-most entry is the originating client.
		first := xff
		if comma := strings.index_byte(xff, ','); comma >= 0 {
			first = xff[:comma]
		}
		first = strings.trim_space(first)
		if is_plausible_address(first) {
			return strings.clone(first, context.temp_allocator)
		}
	}
	return direct
}

@(private = "file")
is_loopback_address :: proc(addr: net.Address) -> bool {
	switch a in addr {
	case net.IP4_Address:
		return a[0] == 127
	case net.IP6_Address:
		// ::1
		for i in 0 ..< 7 {
			if a[i] != 0 {
				return false
			}
		}
		return a[7] == 1
	}
	return false
}

// A header value is only accepted as an address if it *looks* like one.
//
// The value becomes a map key and is compared against other addresses, so
// letting arbitrary header text through would let one client occupy unbounded
// distinct keys in the connection tracker.
@(private = "file")
is_plausible_address :: proc(s: string) -> bool {
	// Longest legal textual form is an IPv4-mapped IPv6 address.
	if len(s) == 0 || len(s) > 45 {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		is_hex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
		if !is_hex && c != '.' && c != ':' {
			return false
		}
	}
	return true
}

handle_ws_request :: proc(socket: net.TCP_Socket, peer: net.Endpoint, req: ^HTTP_Request) {
	// This must be a heap allocation, not a temp one.
	//
	// client_address returns temp-allocated memory, but `ip` has to stay valid
	// until conn_release runs at the end of this procedure — and in between,
	// terminal_loop calls free_all(context.temp_allocator) once per command.
	// Holding the temp string meant conn_release looked up a key made of
	// recycled bytes: the per-IP counter was never decremented, so after
	// MAX_CONNS_PER_IP sessions that address was refused until the process
	// restarted, and a collision would corrupt an unrelated address's count.
	ip := strings.clone(client_address(peer, req))
	defer delete(ip)

	// Terminal session slots are a scarcer resource than page loads.
	if client_count() >= MAX_CLIENTS {
		log_abuse("server_full", ip)
		http_send_status(socket, 503, "Service Unavailable")
		return
	}

	// Per-IP concurrency, enforced here rather than trusting nginx alone.
	if !conn_acquire(&g_conns, ip) {
		log_abuse("per_ip_limit", ip)
		http_send_status(socket, 429, "Too Many Requests")
		return
	}
	defer conn_release(&g_conns, ip)

	if !ws_handshake(socket, req, ip) {
		return
	}

	run_terminal_session(socket, ip)
}

// ---------------------------------------------------------------------------
// Terminal session
// ---------------------------------------------------------------------------

run_terminal_session :: proc(socket: net.TCP_Socket, ip: string) {
	// From here on, recv() returning a timeout is normal: it is how the loop
	// wakes up to send keepalive pings and check the idle deadline.
	net.set_option(socket, .Receive_Timeout, WS_POLL_TIMEOUT)
	net.set_option(socket, .Send_Timeout, WRITE_TIMEOUT)

	client := new(Client)
	client_init(client, socket, next_client_id(), ip)

	conn: WS_Conn
	ws_conn_init(&conn, socket)
	defer ws_conn_destroy(&conn)

	// Start the writer before publishing the client, so no broadcast can queue
	// bytes that nobody would ever drain.
	writer := thread.create(client_writer_proc)
	writer.data = client
	client.writer_thread = writer
	thread.start(writer)

	sync.mutex_lock(&g_clients_lock)
	append(&g_clients, client)
	sync.mutex_unlock(&g_clients_lock)

	send_welcome(client)
	client_send_prompt(client)

	name_for_notice := client_get_name(client, context.temp_allocator)
	broadcast_notice(
		fmt.tprintf(
			"\x1b[33m*\x1b[0m %s connected\r\n",
			name_for_notice,
		),
		client.id,
	)

	terminal_loop(client, &conn)

	// --- Teardown -----------------------------------------------------------
	// Remove from the registry first so no further broadcast can reach this
	// client, then stop the writer, then free. Freeing while still published
	// is exactly the use-after-free the old teardown had.
	sync.mutex_lock(&g_clients_lock)
	for i in 0 ..< len(g_clients) {
		if g_clients[i] == client {
			unordered_remove(&g_clients, i)
			break
		}
	}
	sync.mutex_unlock(&g_clients_lock)

	departed := client_get_name(client, context.temp_allocator)

	client_close(client, .Normal, "bye")
	thread.join(writer)
	thread.destroy(writer) // the old code never destroyed its threads

	client_destroy(client)
	free(client)

	broadcast_notice(fmt.tprintf("\x1b[33m*\x1b[0m %s disconnected\r\n", departed), -1)
}

terminal_loop :: proc(client: ^Client, conn: ^WS_Conn) {
	missed_pongs := 0

	for {
		// Reclaim everything the previous command allocated from the temp
		// arena. Without this the arena grows for the life of the connection,
		// and the old code called fmt.tprintf on literally every keystroke.
		free_all(context.temp_allocator)

		if client_is_dead(client) {
			return
		}

		msg, err := ws_read_message(conn)

		switch err {
		case .None:
			missed_pongs = 0
			client_touch(client)

		case .Timeout:
			// No data this interval. Decide between a keepalive and a hangup.
			if client_idle(client) > IDLE_TIMEOUT {
				client_close(client, .Going_Away, "idle timeout")
				return
			}
			missed_pongs += 1
			if missed_pongs > MAX_MISSED_PONGS {
				return // peer stopped answering
			}
			ping := ws_encode_frame(.Ping, nil, context.temp_allocator)
			client_enqueue(client, ping)
			continue

		case .Closed, .Transport:
			return

		case .Protocol:
			client_close(client, .Protocol_Error, "protocol error")
			return

		case .Too_Large:
			client_close(client, .Too_Large, "message too large")
			return

		case .Invalid_Payload:
			client_close(client, .Invalid_Payload, "invalid utf-8")
			return
		}

		switch msg.opcode {
		case .Text:
			handle_input(client, string(msg.payload))

		case .Binary:
			// The terminal protocol is text-only.
			client_close(client, .Unsupported, "binary frames not supported")
			return

		case .Ping:
			pong := ws_encode_frame(.Pong, msg.payload, context.temp_allocator)
			client_enqueue(client, pong)

		case .Pong:
			// Keepalive answered; last_activity was already refreshed.

		case .Close:
			client_close(client, .Normal, "")
			return

		case .Continuation:
			unreachable() // reassembled by ws_read_message
		}
	}
}

send_welcome :: proc(client: ^Client) {
	b := strings.builder_make(context.temp_allocator)

	strings.write_string(&b, "\x1b[2J\x1b[H")
	strings.write_string(&b, "\x1b[32m")
	strings.write_string(&b, "  __      __   _    ___  ___\r\n")
	strings.write_string(&b, "  \\ \\    / /__| |__/ _ \\/ __|\r\n")
	strings.write_string(&b, "   \\ \\/\\/ / -_) '_ \\ (_) \\__ \\\r\n")
	strings.write_string(&b, "    \\_/\\_/\\___|_.__/\\___/|___/\r\n")
	strings.write_string(&b, "\x1b[0m\r\n")

	fmt.sbprintf(
		&b,
		"  \x1b[90mWebOS %s — an Odin kernel, %d users online\x1b[0m\r\n",
		SERVER_VERSION,
		client_count(),
	)
	strings.write_string(
		&b,
		"  \x1b[90mType \x1b[0m\x1b[36mhelp\x1b[0m\x1b[90m to begin, \x1b[0m\x1b[36mregister\x1b[0m\x1b[90m to claim a name.\x1b[0m\r\n\r\n",
	)

	if motd, ok := vfs_read(&g_vfs, "/etc/motd", "", context.temp_allocator); ok {
		for line in strings.split_lines(motd, context.temp_allocator) {
			if len(line) > 0 {
				fmt.sbprintf(&b, "  \x1b[90m%s\x1b[0m\r\n", line)
			}
		}
		strings.write_string(&b, "\r\n")
	}

	client_send(client, strings.to_string(b))
}

// ---------------------------------------------------------------------------
// Broadcast
// ---------------------------------------------------------------------------

// Delivers a notice to every connected client except `exclude_id`.
//
// This only ever appends to bounded per-client queues, so it cannot block. The
// old implementation performed a blocking send while holding g_clients_lock,
// which let one unresponsive peer freeze every session on the server.
broadcast_notice :: proc(msg: string, exclude_id: int) {
	sync.mutex_lock(&g_clients_lock)
	defer sync.mutex_unlock(&g_clients_lock)

	for c in g_clients {
		if c.id == exclude_id {
			continue
		}
		client_send_notice(c, msg)
	}
}

// Sends raw text (no prompt redraw) to everyone. Used for screen-affecting
// effects that manage their own redraw.
broadcast_raw :: proc(msg: string, exclude_id: int) {
	sync.mutex_lock(&g_clients_lock)
	defer sync.mutex_unlock(&g_clients_lock)

	for c in g_clients {
		if c.id == exclude_id {
			continue
		}
		client_send(c, msg)
	}
}
