package main

import "core:fmt"
import "core:net"
import "core:strings"
import "core:os"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"

handle_http_request :: proc(client: ^Client) {
	buf: [4096]byte
	bytes_read, read_err := net.recv_tcp(client.socket, buf[:])
	if read_err != nil || bytes_read == 0 {
		return
	}

	request_str := string(buf[:bytes_read])
	lines := strings.split(request_str, "\r\n")
	if len(lines) == 0 { return }

	first_line := lines[0]
	parts := strings.split(first_line, " ")
	if len(parts) < 2 { return }

	method := parts[0]
	path := parts[1]

	if method == "GET" && path == "/" {
		serve_index(client.socket)
		return
	}

	if method == "GET" && path == "/ws" {
		ws_key := ""
		for line in lines {
			if strings.has_prefix(line, "Sec-WebSocket-Key: ") {
				ws_key = strings.trim_space(strings.trim_prefix(line, "Sec-WebSocket-Key: "))
				break
			}
		}

		if ws_key != "" {
			do_ws_handshake(client.socket, ws_key)
			handle_ws_connection(client)
		} else {
			send_400(client.socket)
		}
	}
}

serve_index :: proc(socket: net.TCP_Socket) {
	data, err := os.read_entire_file("public/index.html", context.allocator)
	if err != nil {
		send_404(socket)
		return
	}
	defer delete(data)

	response := fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(data), string(data))
	net.send_tcp(socket, transmute([]byte)response)
}

send_404 :: proc(socket: net.TCP_Socket) {
	response := "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n404 Not Found"
	net.send_tcp(socket, transmute([]byte)response)
}

send_400 :: proc(socket: net.TCP_Socket) {
	response := "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n400 Bad Request"
	net.send_tcp(socket, transmute([]byte)response)
}

WS_MAGIC :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

do_ws_handshake :: proc(socket: net.TCP_Socket, key: string) {
	combined := strings.concatenate({key, WS_MAGIC})
	defer delete(combined)

	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)combined)
	hash: [20]byte
	sha1.final(&ctx, hash[:])

	accept_key := base64.encode(hash[:])
	defer delete(accept_key)

	response := fmt.tprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept_key)
	net.send_tcp(socket, transmute([]byte)response)
}