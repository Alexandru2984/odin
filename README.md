# WebOS (Odin)

A collaborative "Fake OS" running in the browser, with a custom backend written in [Odin](https://odin-lang.org/) for raw performance.
All connected users share the same in-memory Virtual File System and can interact in real-time using terminal commands.

## Domain
`https://odin.micutu.com`

## Technologies
- **Backend:** Odin (Core, WebSockets, HTTP)
- **Frontend:** HTML/CSS, Vanilla JS, xterm.js for the terminal interface
- **Server:** Ubuntu on VPS, Nginx Proxy, Let's Encrypt SSL, Systemd

## Status / Completed Plan
- [x] Environment setup (Odin 2026-04).
- [x] Implement base HTTP/WebSocket server in Odin.
- [x] Frontend creation (xterm.js + WebSocket connection).
- [x] Reverse Proxy (Nginx) & SSL Setup (Certbot Let's Encrypt).
- [x] In-memory Virtual File System (VFS) implementation (basic).
- [x] Basic command parsing (ls, cat, echo, whoami, wall).
- [x] Asynchronous service execution (Systemd) with automatic restarts.
- [x] Complete directory system (`mkdir`, `cd`, `pwd`, `rmdir`) and memory management (Extended VFS).
- [x] Advanced **TAB Autocomplete** feature (for commands and files/folders).
- [x] Account system and prompt customization (`login`/`nick` and `color`), interconnected with broadcast events (`wall`).

## Upcoming Features
- Commands with global visual impact (e.g., `clearall` for all visitors or `matrix` for animations on all screens).
- More advanced file editing system.
