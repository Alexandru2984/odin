package main

import "core:fmt"
import "core:net"
import "core:sync"

handle_ws_connection :: proc(client: ^Client) {
	ws_send_text(client, fmt.tprintf("guest_%d@webos:~$ ", client.id))

	for {
		buf: [4096]byte
		bytes_read, read_err := net.recv_tcp(client.socket, buf[:])
		if read_err != nil || bytes_read == 0 {
			break
		}

		if bytes_read >= 6 {
			b1 := buf[1]
			masked := (b1 & 0x80) != 0
			payload_len := int(b1 & 0x7F)
			
			offset := 2
			if payload_len == 126 {
				offset = 4
			} else if payload_len == 127 {
				offset = 10
			}

			if masked && bytes_read >= offset + 4 {
				masking_key := buf[offset:offset+4]
				payload := buf[offset+4:bytes_read]
				
				for i in 0..<len(payload) {
					payload[i] ~= masking_key[i % 4]
				}
				
				text := string(payload)
				for i in 0..<len(text) {
					char := text[i]
					if char == '\r' || char == '\n' {
						ws_send_text(client, "\r\n")
						cmd := string(client.input_buffer[:client.input_len])
						process_command(client, cmd)
						client.input_len = 0
						ws_send_text(client, fmt.tprintf("guest_%d@webos:~$ ", client.id))
					} else if char == '\x7f' || char == '\b' {
						if client.input_len > 0 {
							client.input_len -= 1
							ws_send_text(client, "\b \b")
						}
					} else {
						if client.input_len < 256 {
							client.input_buffer[client.input_len] = char
							client.input_len += 1
							ws_send_text(client, fmt.tprintf("%c", char))
						}
					}
				}
			}
		}
	}
}

ws_send_text :: proc(client: ^Client, text: string) {
	text_bytes := transmute([]byte)text
	length := len(text_bytes)
	
	header: [10]byte
	header[0] = 0x81 // FIN + Text opcode
	
	h_len := 0
	if length <= 125 {
		header[1] = byte(length)
		h_len = 2
	} else if length <= 65535 {
		header[1] = 126
		header[2] = byte((length >> 8) & 0xFF)
		header[3] = byte(length & 0xFF)
		h_len = 4
	} else {
		return
	}

	sync.mutex_lock(&client.send_lock)
	defer sync.mutex_unlock(&client.send_lock)

	net.send_tcp(client.socket, header[:h_len])
	net.send_tcp(client.socket, text_bytes)
}