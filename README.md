# WebOS (Odin)

Un "Fake OS" colaborativ rulat în browser, cu backend scris în [Odin](https://odin-lang.org/) pentru performanță brută.
Toți utilizatorii conectați împart același sistem de fișiere virtual în memorie și pot interacționa în timp real prin comenzi de terminal.

## Domeniu
`odin.micutu.com`

## Tehnologii
- **Backend:** Odin (Core, WebSockets, HTTP)
- **Frontend:** HTML/CSS, Vanilla JS, xterm.js pentru interfața de terminal
- **Server:** Ubuntu pe VPS

## Plan
1. Setup mediu (Odin, librării necesare).
2. Implementare server HTTP/WebSocket de bază în Odin.
3. Creare Frontend (xterm.js + conectare WebSocket).
4. Implementare Virtual File System (VFS) în memorie.
5. Parsare comenzi (ls, cd, cat, echo, etc) și broadcasting către clienți.
6. Deploy și testare pe `odin.micutu.com`.
