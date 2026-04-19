package main

import "core:fmt"
import "core:strings"
import "core:sync"

handle_autocomplete :: proc(client: ^Client) {
	if client.input_len == 0 { return }
	current_input := string(client.input_buffer[:client.input_len])
	
	last_space_idx := strings.last_index(current_input, " ")
	
	prefix := ""
	is_cmd := false
	if last_space_idx == -1 {
		is_cmd = true
		prefix = current_input
	} else {
		prefix = current_input[last_space_idx+1:]
	}
	
	if prefix == "" { return }

	matches := make([dynamic]string)
	defer {
		for m in matches { delete(m) }
		delete(matches)
	}

	if is_cmd {
		commands := []string{"ls", "cd", "pwd", "mkdir", "rmdir", "rm", "echo", "cat", "wall", "whoami", "help", "login", "color"}
		for c in commands {
			if strings.has_prefix(c, prefix) {
				append(&matches, strings.clone(c))
			}
		}
	} else {
		dir_part := ""
		base_part := prefix
		last_slash := strings.last_index(prefix, "/")
		if last_slash != -1 {
			dir_part = prefix[:last_slash]
			if dir_part == "" { dir_part = "/" }
			base_part = prefix[last_slash+1:]
		}
		
		target_dir := client.cwd
		if dir_part != "" {
			target_dir = vfs_resolve_path(client.cwd, dir_part)
		}
		
		names, ok := vfs_list(&g_vfs, target_dir)
		if ok {
			defer { for n in names { delete(n) }; delete(names) }
			for n in names {
				if strings.has_prefix(n, base_part) {
					full_p := vfs_resolve_path(target_dir, n)
					res := strings.clone(n)
					if vfs_is_dir(&g_vfs, full_p) {
						res2 := strings.concatenate({res, "/"})
						delete(res)
						res = res2
					}
					delete(full_p)
					append(&matches, res)
				}
			}
		}
	}

	if len(matches) == 1 {
		match := matches[0]
		base_to_complete := prefix
		if !is_cmd {
			last_slash := strings.last_index(prefix, "/")
			if last_slash != -1 {
				base_to_complete = prefix[last_slash+1:]
			}
		}

		suffix := match[len(base_to_complete):]
		if len(suffix) > 0 {
			for i in 0..<len(suffix) {
				if client.input_len < 256 {
					client.input_buffer[client.input_len] = suffix[i]
					client.input_len += 1
				}
			}
			ws_send_text(client, suffix)
			
			if !strings.has_suffix(match, "/") && client.input_len < 256 {
				client.input_buffer[client.input_len] = ' '
				client.input_len += 1
				ws_send_text(client, " ")
			}
		}
	} else if len(matches) > 1 {
		ws_send_text(client, "\r\n")
		for m in matches {
			ws_send_text(client, fmt.tprintf("%s  ", m))
		}
		ws_send_text(client, "\r\n")
		ws_send_text(client, fmt.tprintf("\x1b[%sm%s\x1b[0m@webos:%s$ %s", client.color, client.name, client.cwd, current_input))
	}
}

process_command :: proc(client: ^Client, cmd_line: string) {
	cmd_line_trim := strings.trim_space(cmd_line)
	if cmd_line_trim == "" { return }

	parts := strings.split(cmd_line_trim, " ")
	cmd := parts[0]
	defer delete(parts)

	if cmd == "pwd" {
		ws_send_text(client, fmt.tprintf("%s\r\n", client.cwd))
	} else if cmd == "cd" {
		if len(parts) < 2 {
			client.cwd = "/"
			ws_send_text(client, "\r\n")
		} else {
			target := vfs_resolve_path(client.cwd, parts[1])
			if vfs_is_dir(&g_vfs, target) {
				client.cwd = target
			} else {
				ws_send_text(client, fmt.tprintf("cd: %s: No such file or directory\r\n", parts[1]))
			}
		}
	} else if cmd == "mkdir" {
		if len(parts) < 2 {
			ws_send_text(client, "mkdir: missing operand\r\n")
			return
		}
		target := vfs_resolve_path(client.cwd, parts[1])
		if vfs_mkdir(&g_vfs, target) {
			broadcast_message(fmt.tprintf("\r\n\x1b[33m[System]\x1b[0m \x1b[%sm%s\x1b[0m created directory '%s'\r\n", client.color, client.name, parts[1]), client.id)
		} else {
			ws_send_text(client, fmt.tprintf("mkdir: cannot create directory '%s': File exists or parent missing\r\n", parts[1]))
		}
	} else if cmd == "rmdir" {
		if len(parts) < 2 {
			ws_send_text(client, "rmdir: missing operand\r\n")
			return
		}
		target := vfs_resolve_path(client.cwd, parts[1])
		if vfs_rmdir(&g_vfs, target) {
			broadcast_message(fmt.tprintf("\r\n\x1b[33m[System]\x1b[0m \x1b[%sm%s\x1b[0m removed directory '%s'\r\n", client.color, client.name, parts[1]), client.id)
		} else {
			ws_send_text(client, fmt.tprintf("rmdir: failed to remove '%s'\r\n", parts[1]))
		}
	} else if cmd == "rm" {
		if len(parts) < 2 {
			ws_send_text(client, "rm: missing operand\r\n")
			return
		}
		target := vfs_resolve_path(client.cwd, parts[1])
		if vfs_rm(&g_vfs, target) {
			broadcast_message(fmt.tprintf("\r\n\x1b[33m[System]\x1b[0m \x1b[%sm%s\x1b[0m deleted file '%s'\r\n", client.color, client.name, parts[1]), client.id)
		} else {
			ws_send_text(client, fmt.tprintf("rm: cannot remove '%s': No such file\r\n", parts[1]))
		}
	} else if cmd == "ls" {
		target := client.cwd
		if len(parts) >= 2 {
			target = vfs_resolve_path(client.cwd, parts[1])
		}
		names, ok := vfs_list(&g_vfs, target)
		if ok {
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
		} else {
			ws_send_text(client, fmt.tprintf("ls: cannot access '%s': No such file or directory\r\n", parts[1] if len(parts)>=2 else client.cwd))
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
				if len(text_to_echo) >= 2 { text_to_echo = text_to_echo[1:len(text_to_echo)-1] }
			}
			
			if file_target != "" {
				target := vfs_resolve_path(client.cwd, file_target)
				if vfs_write(&g_vfs, target, text_to_echo) {
					broadcast_message(fmt.tprintf("\r\n\x1b[33m[System]\x1b[0m \x1b[%sm%s\x1b[0m created/updated file '%s'\r\n", client.color, client.name, target), client.id)
				} else {
					ws_send_text(client, fmt.tprintf("echo: cannot create file '%s': Parent directory missing or is a directory\r\n", target))
				}
			} else {
				ws_send_text(client, "echo: missing file name\r\n")
			}
		} else {
			if len(cmd_line_trim) > 4 {
				text_to_echo = strings.trim_space(cmd_line_trim[4:])
			}
			if strings.has_prefix(text_to_echo, "\"") && strings.has_suffix(text_to_echo, "\"") {
				if len(text_to_echo) >= 2 { text_to_echo = text_to_echo[1:len(text_to_echo)-1] }
			}
			ws_send_text(client, fmt.tprintf("%s\r\n", text_to_echo))
		}
	} else if cmd == "cat" {
		if len(parts) < 2 {
			ws_send_text(client, "cat: missing file name\r\n")
			return
		}
		target := vfs_resolve_path(client.cwd, parts[1])
		content, ok := vfs_read(&g_vfs, target)
		if ok {
			defer delete(content)
			lines := strings.split(content, "\n")
			defer delete(lines)
			for line in lines {
				ws_send_text(client, fmt.tprintf("%s\r\n", line))
			}
		} else {
			ws_send_text(client, fmt.tprintf("cat: %s: No such file or directory\r\n", parts[1]))
		}
	} else if cmd == "wall" {
		msg := ""
		if len(cmd_line_trim) > 4 { msg = strings.trim_space(cmd_line_trim[4:]) }
		if msg != "" {
			broadcast_message(fmt.tprintf("\r\n\x1b[31m[WALL]\x1b[0m \x1b[%sm%s\x1b[0m: %s\r\n", client.color, client.name, msg), client.id)
			ws_send_text(client, "Message sent to everyone.\r\n")
		} else {
			ws_send_text(client, "wall: missing message\r\n")
		}
	} else if cmd == "whoami" {
		ws_send_text(client, fmt.tprintf("\x1b[%sm%s\x1b[0m\r\n", client.color, client.name))
	} else if cmd == "login" || cmd == "nick" {
		if len(parts) < 2 {
			ws_send_text(client, "login: missing name\r\n")
			return
		}
		new_name := parts[1]
		if len(new_name) > 20 {
			ws_send_text(client, "login: name too long (max 20 chars)\r\n")
			return
		}
		
		old_name := client.name
		client.name = strings.clone(new_name)
		
		broadcast_message(fmt.tprintf("\r\n\x1b[33m[System]\x1b[0m \x1b[%sm%s\x1b[0m is now known as \x1b[%sm%s\x1b[0m\r\n", client.color, old_name, client.color, client.name), client.id)
		ws_send_text(client, fmt.tprintf("You are now known as \x1b[%sm%s\x1b[0m\r\n", client.color, client.name))
		delete(old_name)

	} else if cmd == "color" {
		if len(parts) < 2 {
			ws_send_text(client, "color: missing color code (e.g. 31=red, 32=green, 33=yellow, 34=blue, 35=magenta, 36=cyan)\r\n")
			return
		}
		color_code := parts[1]
		if color_code >= "31" && color_code <= "36" {
			client.color = color_code // This is a static literal string slice so we don't clone it
			ws_send_text(client, fmt.tprintf("Color changed to \x1b[%sm%s\x1b[0m\r\n", client.color, color_code))
		} else {
			ws_send_text(client, "color: invalid color code. Use 31 to 36.\r\n")
		}
	} else if cmd == "matrix" {
		broadcast_message(fmt.tprintf("\r\n\x1b[32m[System] \x1b[%sm%s\x1b[0m \x1b[32minitiated the Matrix sequence...\x1b[0m\r\n___MATRIX_START___", client.color, client.name), -1)
	} else if cmd == "clearall" {
		// \x1b[2J clears the screen, \x1b[3J clears scrollback, \x1b[H moves cursor to home
		broadcast_message("\x1b[2J\x1b[3J\x1b[H", -1)
	} else if cmd == "help" {
		ws_send_text(client, "Commands: ls, cd, pwd, mkdir, rmdir, rm, echo, cat, wall, whoami, login, color, matrix, clearall, help\r\n")
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
			ws_send_text(c, fmt.tprintf("\x1b[%sm%s\x1b[0m@webos:%s$ ", c.color, c.name, c.cwd))
		}
	}
}