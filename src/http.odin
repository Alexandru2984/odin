package main

import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:os"
import path "core:path/slashpath"
import "core:strings"

// ---------------------------------------------------------------------------
// HTTP front end
//
// The previous version read a single 4 KiB recv() and treated whatever arrived
// as a complete request. A request head split across packets was rejected, and
// a request larger than the buffer was silently truncated. It also had no
// timeout, so an open connection that never sent anything held a thread
// forever (slowloris), and no Origin check, so any website on the internet
// could open a WebSocket to this server on a visitor's behalf.
// ---------------------------------------------------------------------------

HTTP_Request :: struct {
	method:  string,
	target:  string,
	version: string,
	// Header names are lower-cased. Values borrow the raw request buffer.
	headers: map[string]string,
}

http_request_destroy :: proc(r: ^HTTP_Request) {
	delete(r.headers)
}

http_header :: proc(r: ^HTTP_Request, name: string) -> string {
	return r.headers[name] or_else ""
}

// Reads and parses the request head, bounded in both size and time.
//
// `raw` receives the accumulated bytes; header values borrow from it, so it
// must outlive the request.
http_read_request :: proc(
	socket: net.TCP_Socket,
	raw: ^[dynamic]byte,
) -> (req: HTTP_Request, ok: bool) {
	// Slowloris bound: the whole head must arrive within this window.
	net.set_option(socket, .Receive_Timeout, HANDSHAKE_TIMEOUT)

	head_end := -1
	for {
		tmp: [4096]byte
		n, err := net.recv_tcp(socket, tmp[:])
		if err != nil || n == 0 {
			return {}, false
		}
		append(raw, ..tmp[:n])

		if idx := index_of_crlfcrlf(raw[:]); idx >= 0 {
			head_end = idx
			break
		}

		if len(raw) > MAX_HTTP_REQUEST {
			return {}, false // head never terminated
		}
	}

	return http_parse_head(string(raw[:head_end]))
}

@(private = "file")
index_of_crlfcrlf :: proc(data: []byte) -> int {
	if len(data) < 4 {
		return -1
	}
	for i in 0 ..= len(data) - 4 {
		if data[i] == '\r' && data[i + 1] == '\n' && data[i + 2] == '\r' && data[i + 3] == '\n' {
			return i
		}
	}
	return -1
}

http_parse_head :: proc(head: string) -> (req: HTTP_Request, ok: bool) {
	lines := strings.split(head, "\r\n", context.temp_allocator)
	if len(lines) == 0 {
		return {}, false
	}

	parts := strings.split(lines[0], " ", context.temp_allocator)
	if len(parts) < 3 {
		return {}, false
	}

	req.method = parts[0]
	req.target = parts[1]
	req.version = parts[2]
	req.headers = make(map[string]string, context.temp_allocator)

	if len(req.target) > 2048 {
		return {}, false
	}

	for i in 1 ..< len(lines) {
		line := lines[i]
		if len(line) == 0 {
			continue
		}
		if len(req.headers) >= MAX_HEADER_COUNT {
			break
		}

		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			continue
		}

		name := strings.to_lower(strings.trim_space(line[:colon]), context.temp_allocator)
		value := strings.trim_space(line[colon + 1:])
		req.headers[name] = value
	}

	return req, true
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

http_send_response :: proc(
	socket: net.TCP_Socket,
	status: int,
	status_text: string,
	content_type: string,
	body: []byte,
	extra_headers: string = "",
) {
	head := fmt.tprintf(
		"HTTP/1.1 %d %s\r\n" +
		"Content-Type: %s\r\n" +
		"Content-Length: %d\r\n" +
		"X-Content-Type-Options: nosniff\r\n" +
		"Connection: close\r\n" +
		"%s" +
		"\r\n",
		status,
		status_text,
		content_type,
		len(body),
		extra_headers,
	)

	send_all(socket, transmute([]byte)head)
	if len(body) > 0 {
		send_all(socket, body)
	}
}

http_send_status :: proc(socket: net.TCP_Socket, status: int, status_text: string) {
	body := fmt.tprintf("%d %s\n", status, status_text)
	http_send_response(socket, status, status_text, "text/plain; charset=utf-8", transmute([]byte)body)
}

// ---------------------------------------------------------------------------
// Static files
// ---------------------------------------------------------------------------

PUBLIC_DIR :: "public"

mime_type :: proc(file_path: string) -> string {
	ext := path.ext(file_path)
	switch ext {
	case ".html":
		return "text/html; charset=utf-8"
	case ".css":
		return "text/css; charset=utf-8"
	case ".js", ".mjs":
		return "text/javascript; charset=utf-8"
	case ".json":
		return "application/json; charset=utf-8"
	case ".svg":
		return "image/svg+xml"
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".ico":
		return "image/x-icon"
	case ".woff2":
		return "font/woff2"
	case ".woff":
		return "font/woff"
	case ".webmanifest":
		return "application/manifest+json"
	case ".txt":
		return "text/plain; charset=utf-8"
	case ".map":
		return "application/json; charset=utf-8"
	}
	return "application/octet-stream"
}

// Decodes %XX escapes. Returns ok=false on a malformed sequence rather than
// passing the raw bytes through, since a half-decoded path is exactly how
// traversal filters get bypassed.
percent_decode :: proc(s: string, allocator := context.temp_allocator) -> (out: string, ok: bool) {
	b := strings.builder_make(allocator)

	i := 0
	for i < len(s) {
		c := s[i]
		if c == '%' {
			if i + 2 >= len(s) {
				return "", false
			}
			hi, hi_ok := hex_value(s[i + 1])
			lo, lo_ok := hex_value(s[i + 2])
			if !hi_ok || !lo_ok {
				return "", false
			}
			decoded := byte(hi << 4 | lo)
			// A NUL byte would truncate the path for any C-level consumer.
			if decoded == 0 {
				return "", false
			}
			strings.write_byte(&b, decoded)
			i += 3
		} else {
			strings.write_byte(&b, c)
			i += 1
		}
	}

	return strings.to_string(b), true
}

@(private = "file")
hex_value :: proc(c: byte) -> (val: int, ok: bool) {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0'), true
	case c >= 'a' && c <= 'f':
		return int(c - 'a') + 10, true
	case c >= 'A' && c <= 'F':
		return int(c - 'A') + 10, true
	}
	return 0, false
}

// Maps a request target to a path inside PUBLIC_DIR.
//
// Defence in depth against traversal: percent-escapes are decoded first (so
// %2e%2e%2f cannot smuggle a "..") , backslashes are rejected, the result is
// lexically cleaned, and the cleaned path is re-checked for any remaining
// parent reference before being joined onto the public root.
resolve_static_path :: proc(target: string, allocator := context.temp_allocator) -> (
	file_path: string,
	ok: bool,
) {
	// Strip the query string and fragment.
	req_path := target
	if q := strings.index_byte(req_path, '?'); q >= 0 {
		req_path = req_path[:q]
	}
	if h := strings.index_byte(req_path, '#'); h >= 0 {
		req_path = req_path[:h]
	}

	decoded, decode_ok := percent_decode(req_path)
	if !decode_ok {
		return "", false
	}

	if len(decoded) == 0 || decoded[0] != '/' {
		return "", false
	}
	// NUL or control bytes have no business in a path.
	if !is_clean_text(decoded) {
		return "", false
	}
	if strings.contains(decoded, "\\") {
		return "", false
	}

	cleaned := path.clean(decoded, context.temp_allocator)

	// path.clean resolves ".." lexically and cannot escape "/", but check
	// explicitly rather than relying on that as the only barrier.
	if strings.contains(cleaned, "..") {
		return "", false
	}

	// Hidden files are never served.
	for seg in strings.split(cleaned, "/", context.temp_allocator) {
		if len(seg) > 0 && seg[0] == '.' {
			return "", false
		}
	}

	if cleaned == "/" {
		cleaned = "/index.html"
	}

	return strings.concatenate({PUBLIC_DIR, cleaned}, allocator), true
}

http_serve_static :: proc(socket: net.TCP_Socket, target: string) {
	file_path, ok := resolve_static_path(target)
	if !ok {
		http_send_status(socket, 400, "Bad Request")
		return
	}

	data, err := os.read_entire_file(file_path, context.temp_allocator)
	if err != nil {
		http_send_status(socket, 404, "Not Found")
		return
	}

	// index.html changes with every deploy; hashed-in-name assets do not, but
	// nothing here is fingerprinted yet, so keep revalidation cheap instead of
	// caching aggressively and serving a stale terminal.
	cache := "Cache-Control: no-cache\r\n"
	if !strings.has_suffix(file_path, ".html") {
		cache = "Cache-Control: public, max-age=3600\r\n"
	}

	http_send_response(socket, 200, "OK", mime_type(file_path), data, cache)
}

// ---------------------------------------------------------------------------
// WebSocket handshake
// ---------------------------------------------------------------------------

WS_MAGIC :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// Origins permitted to open a WebSocket.
//
// Without this check any page on the internet could open
// wss://odin.micutu.com/ws in a visitor's browser and drive the shared VFS and
// broadcast channel as them — cross-site WebSocket hijacking. The same-origin
// policy does not apply to WebSockets, so the server has to enforce it.
allowed_origins :: proc() -> []string {
	if env := os.get_env("WEBOS_ALLOWED_ORIGINS", context.temp_allocator); len(env) > 0 {
		return strings.split(env, ",", context.temp_allocator)
	}
	return DEFAULT_ALLOWED_ORIGINS[:]
}

origin_allowed :: proc(origin: string) -> bool {
	// A browser always sends Origin on a WebSocket handshake. Its absence
	// means a non-browser client, which cannot be a hijacking victim, so it is
	// permitted here and constrained by the rate limits instead.
	if len(origin) == 0 {
		return true
	}

	for allowed in allowed_origins() {
		if strings.trim_space(allowed) == origin {
			return true
		}
	}
	return false
}

// Performs the RFC 6455 opening handshake. Returns false if the request is not
// a valid or permitted upgrade, having already sent an error response.
ws_handshake :: proc(socket: net.TCP_Socket, req: ^HTTP_Request) -> bool {
	if !strings.contains(
		strings.to_lower(http_header(req, "upgrade"), context.temp_allocator),
		"websocket",
	) {
		http_send_status(socket, 400, "Bad Request")
		return false
	}

	origin := http_header(req, "origin")
	if !origin_allowed(origin) {
		http_send_status(socket, 403, "Forbidden")
		return false
	}

	// RFC 6455 requires version 13.
	if version := http_header(req, "sec-websocket-version"); version != "13" {
		http_send_response(
			socket,
			426,
			"Upgrade Required",
			"text/plain; charset=utf-8",
			transmute([]byte)string("unsupported websocket version\n"),
			"Sec-WebSocket-Version: 13\r\n",
		)
		return false
	}

	key := http_header(req, "sec-websocket-key")
	// The key is a base64-encoded 16-byte nonce, so it is always 24 characters.
	if len(key) != 24 {
		http_send_status(socket, 400, "Bad Request")
		return false
	}

	combined := strings.concatenate({key, WS_MAGIC}, context.temp_allocator)

	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)combined)
	digest: [20]byte
	sha1.final(&ctx, digest[:])

	accept := base64.encode(digest[:], base64.ENC_TABLE, context.temp_allocator)

	response := fmt.tprintf(
		"HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: %s\r\n" +
		"\r\n",
		accept,
	)

	return send_all(socket, transmute([]byte)response)
}
