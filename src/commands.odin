package main

import "core:fmt"
import "core:strings"
import "core:sync"

process_command :: proc(client: ^Client, cmd_line: string) {
	cmd_line_trim := strings.trim_space(cmd_line)
	if cmd_line_trim == "" {
		return
	}

	parts := strings.split(cmd_line_trim, " ")
	cmd := parts[0]
	defer delete(parts)

	if cmd == "ls" {
		names := vfs_list(&g_vfs)
		defer {
			for n in names { delete(n) }
			delete(names)
		}
		
		if len(names) == 0 {
			ws_send_text(client, "Directory is empty.\r\n")
		} else {
			for n in names {
				ws_send_text(client, fmt.tprintf("%s\r\n", n))
			}
		}
	} else if cmd == "echo" {
		text_to_echo := ""
		file_target := ""
		
		idx := strings.index(cmd_line_trim, ">")
		if idx != -1 {
			if idx > 4 {
				text_to_echo = strings.trim_space(cmd_line_trim[4:idx])
			}
			file_target = strings.trim_space(cmd_line_trim[idx+1:])
			
			if strings.has_prefix(text_to_echo, "\"") && strings.has_suffix(text_to_echo, "\"") {
				if len(text_to_echo) >= 2 {
					text_to_echo = text_to_echo[1:len(text_to_echo)-1]
				}
			}
			
			if file_target != "" {
				vfs_write(&g_vfs, file_target, text_to_echo)
				broadcast_message(fmt.tprintf("\r\n\x1b[33m[System]\x1b[0m guest_%d created/updated file '%s'\r\n", client.id, file_target), client.id)
			} else {
				ws_send_text(client, "echo: missing file name\r\n")
			}
		} else {
			if len(cmd_line_trim) > 4 {
				text_to_echo = strings.trim_space(cmd_line_trim[4:])
			}
			if strings.has_prefix(text_to_echo, "\"") && strings.has_suffix(text_to_echo, "\"") {
				if len(text_to_echo) >= 2 {
					text_to_echo = text_to_echo[1:len(text_to_echo)-1]
				}
			}
			ws_send_text(client, fmt.tprintf("%s\r\n", text_to_echo))
		}
	} else if cmd == "cat" {
		if len(parts) < 2 {
			ws_send_text(client, "cat: missing file name\r\n")
			return
		}
		file_name := parts[1]
		content, ok := vfs_read(&g_vfs, file_name)
		if ok {
			defer delete(content)
			lines := strings.split(content, "\n")
			defer delete(lines)
			for line in lines {
				ws_send_text(client, fmt.tprintf("%s\r\n", line))
			}
		} else {
			ws_send_text(client, fmt.tprintf("cat: %s: No such file or directory\r\n", file_name))
		}
	} else if cmd == "wall" {
		msg := ""
		if len(cmd_line_trim) > 4 {
			msg = strings.trim_space(cmd_line_trim[4:])
		}
		if msg != "" {
			broadcast_message(fmt.tprintf("\r\n\x1b[31m[WALL]\x1b[0m guest_%d: %s\r\n", client.id, msg), client.id)
			ws_send_text(client, "Message sent to everyone.\r\n")
		} else {
			ws_send_text(client, "wall: missing message\r\n")
		}
	} else if cmd == "whoami" {
		ws_send_text(client, fmt.tprintf("guest_%d\r\n", client.id))
	} else if cmd == "help" {
		ws_send_text(client, "Available commands: ls, echo, cat, wall, whoami, help\r\n")
		ws_send_text(client, "Examples:\r\n")
		ws_send_text(client, "  echo \"hello world\" > test.txt\r\n")
		ws_send_text(client, "  cat test.txt\r\n")
		ws_send_text(client, "  wall hello everyone!\r\n")
	} else {
		ws_send_text(client, fmt.tprintf("webos: %s: command not found\r\n", cmd))
	}
}

broadcast_message :: proc(msg: string, exclude_id: int) {
	sync.mutex_lock(&g_clients_lock)
	defer sync.mutex_unlock(&g_clients_lock)

	for c in g_clients {
		if c.id != exclude_id {
			ws_send_text(c, msg)
			ws_send_text(c, fmt.tprintf("guest_%d@webos:~$ ", c.id))
		}
	}
}