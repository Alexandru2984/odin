package main

import "core:net"
import "core:sys/linux"

// Socket options that core:net cannot set correctly.
//
// net.set_option(sock, .Send_Buffer_Size, 128 * 1024) returns no error and does
// not do what it says. In core/net/socket_linux.odin the buffer-size branch is
//
//     switch i in value {
//     case int, uint: i2 := i; int_value = i32((^uint)(&i2)^)
//
// and because that case lists two types, `i` is not narrowed — it stays `any`.
// So `&i2` is the address of an `any`, and the cast reads its *data pointer*
// rather than the integer behind it. The kernel receives a pointer-sized number,
// clamps it to net.core.wmem_max, and reports success. Measured on this machine:
// asking for 128 KB moved sk_sndbuf from 2626560 to 8388608 — the opposite of
// the intent — while the same request through setsockopt gives 262144, which is
// the 128 KB the kernel doubles for its own bookkeeping. Every integer case in
// that switch has the same shape, so Receive_Buffer_Size is wrong in the same
// way; only the timeout and boolean options are single-typed and sound.
//
// This file is _linux because the syscall is. The server has never been built
// for anything else, and on another platform the missing symbol says so loudly
// instead of quietly not applying a limit that other code depends on.

@(private = "file")
SOL_SOCKET_LEVEL :: linux.Socket_API_Level_Sock.SOCKET

// Pins the kernel send buffer for one connection. Returns false if the kernel
// refused, which is not fatal — it means backpressure lands later than intended,
// not that the connection is unusable.
set_send_buffer :: proc(socket: net.TCP_Socket, bytes: int) -> bool {
	want := i32(bytes)
	err := linux.setsockopt(linux.Fd(socket), SOL_SOCKET_LEVEL, linux.Socket_Option.SNDBUF, &want)
	return err == .NONE
}
