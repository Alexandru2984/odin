# WebOS (Odin)

Un "Fake OS" colaborativ rulat în browser, cu backend scris în [Odin](https://odin-lang.org/) pentru performanță brută.
Toți utilizatorii conectați împart același sistem de fișiere virtual în memorie și pot interacționa în timp real prin comenzi de terminal.

## Domeniu
`https://odin.micutu.com`

## Tehnologii
- **Backend:** Odin (Core, WebSockets, HTTP)
- **Frontend:** HTML/CSS, Vanilla JS, xterm.js pentru interfața de terminal
- **Server:** Ubuntu pe VPS, Nginx Proxy, Let's Encrypt SSL

## Status / Plan Realizat
- [x] Setup mediu (Odin 2026-04).
- [x] Implementare server HTTP/WebSocket de bază în Odin.
- [x] Creare Frontend (xterm.js + conectare WebSocket).
- [x] Setup Reverse Proxy (Nginx) & SSL (Certbot Let's Encrypt).
- [x] Implementare Virtual File System (VFS) în memorie (simplu).
- [x] Parsare comenzi (ls, cat, echo, whoami, wall) și broadcasting către clienți.

## Funcționalități Următoare
- Sistem de permisiuni, culori, ierarhii de foldere (mkdir/cd).
- Editare multi-linie sau comenzi complexe de administrare.
- Comenzi cu impact global vizual (ex: `clear` for all).
