package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:thread"
import "core:sync"

PORT :: 47271

Client :: struct {
	socket:       net.TCP_Socket,
	id:           int,
	input_buffer: [256]byte,
	input_len:    int,
	send_lock:    sync.Mutex,
}

g_vfs: VFS
g_clients: [dynamic]^Client
g_clients_lock: sync.Mutex

main :: proc() {
	vfs_init(&g_vfs)
	g_clients = make([dynamic]^Client)

	endpoint, parse_ok := net.parse_endpoint("0.0.0.0:47271")
	if !parse_ok {
		fmt.eprintln("Failed to parse endpoint")
		os.exit(1)
	}

	server_socket, listen_err := net.listen_tcp(endpoint)
	if listen_err != nil {
		fmt.eprintln("Failed to listen on port", PORT, ":", listen_err)
		os.exit(1)
	}
	defer net.close(server_socket)

	fmt.println("WebOS Core initialized. Listening on port", PORT)

	client_id_counter := 1

	for {
		client_socket, client_endpoint, accept_err := net.accept_tcp(server_socket)
		if accept_err != nil {
			fmt.eprintln("Failed to accept:", accept_err)
			continue
		}

		fmt.println("Client connected:", client_endpoint)

		client_ptr := new(Client)
		client_ptr.socket = client_socket
		client_ptr.id = client_id_counter
		client_id_counter += 1

		sync.mutex_lock(&g_clients_lock)
		append(&g_clients, client_ptr)
		sync.mutex_unlock(&g_clients_lock)

		t := thread.create(client_handler)
		t.user_index = client_ptr.id
		t.data = client_ptr
		thread.start(t)
	}
}

client_handler :: proc(t: ^thread.Thread) {
	client := cast(^Client)t.data
	
	handle_http_request(client)
	
	fmt.println("Client disconnected:", client.id)
	
	sync.mutex_lock(&g_clients_lock)
	for i in 0..<len(g_clients) {
		if g_clients[i].id == client.id {
			unordered_remove(&g_clients, i)
			break
		}
	}
	sync.mutex_unlock(&g_clients_lock)

	net.close(client.socket)
	free(client)
}