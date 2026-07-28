/*
 * WebOS front end.
 *
 * A *session* is one terminal and one WebSocket: its own shell on the server,
 * with its own directory, variables and history. Classic mode runs exactly one
 * filling the page. The desktop runs several, each in a window, which is why
 * everything about a connection lives in a factory rather than in the module
 * scope it used to occupy — there is no longer "the" terminal or "the" socket.
 *
 * Everything shared by every session — theme, font size, the matrix overlay,
 * the touch key bar — stays here, because it belongs to the page rather than
 * to any one shell.
 */
(function () {
  const $ = (id) => document.getElementById(id);

  const els = {
    app: $('app'),
    classicHost: $('terminal'),
    termHost: $('terminal-host'),
    connDot: $('conn-dot'),
    connLabel: $('conn-label'),
    offline: $('offline'),
    offlineDetail: $('offline-detail'),
    retry: $('btn-retry'),
    keybar: $('keybar'),
    ctrlKey: $('key-ctrl'),
    matrix: $('matrix'),
    fontIn: $('btn-font-in'),
    fontOut: $('btn-font-out'),
    theme: $('btn-theme'),
    mode: $('btn-mode'),
    desktop: $('desktop'),
  };

  // --- preferences ---------------------------------------------------------
  // localStorage can throw outright in private-browsing modes, so every access
  // is guarded. A failed preference read must not stop the terminal loading.

  const store = {
    get(key, fallback) {
      try {
        const v = localStorage.getItem(key);
        return v === null ? fallback : v;
      } catch (_) {
        return fallback;
      }
    },
    set(key, value) {
      try {
        localStorage.setItem(key, value);
      } catch (_) {
        /* preferences are a nicety, not a requirement */
      }
    },
  };

  const THEMES = ['dark', 'amber', 'ocean', 'mono', 'paper'];

  const MIN_FONT = 10;
  const MAX_FONT = 22;

  function clamp(n, lo, hi) {
    return Math.min(hi, Math.max(lo, n));
  }

  function defaultFontSize() {
    return window.innerWidth < 600 ? 13 : 15;
  }

  let fontSize = clamp(
    parseInt(store.get('webos.font', ''), 10) || defaultFontSize(),
    MIN_FONT,
    MAX_FONT
  );
  let themeName = THEMES.includes(store.get('webos.theme', ''))
    ? store.get('webos.theme', 'dark')
    : 'dark';

  // The sessions currently alive, and which one the keyboard belongs to.
  const sessions = new Set();
  let active = null;

  // --- theme ---------------------------------------------------------------

  // Reads the palette back out of CSS so the terminal and the page chrome can
  // never disagree about what the current theme looks like.
  function paletteFromCSS() {
    const css = getComputedStyle(document.documentElement);
    const v = (name, fallback) => css.getPropertyValue(name).trim() || fallback;
    return {
      background: v('--term-bg', '#0b0f0d'),
      foreground: v('--term-fg', '#d8e6de'),
      cursor: v('--accent', '#35d07f'),
      cursorAccent: v('--term-bg', '#0b0f0d'),
      selectionBackground: v('--selection', 'rgba(53,208,127,0.28)'),
      black: v('--c0', '#1c2521'),
      red: v('--c1', '#ff6b6b'),
      green: v('--c2', '#35d07f'),
      yellow: v('--c3', '#f2c94c'),
      blue: v('--c4', '#5aa9e6'),
      magenta: v('--c5', '#c792ea'),
      cyan: v('--c6', '#56d4dd'),
      white: v('--c7', '#d8e6de'),
      brightBlack: v('--c8', '#4a5a53'),
      brightRed: v('--c9', '#ff8787'),
      brightGreen: v('--c10', '#5ee79f'),
      brightYellow: v('--c11', '#ffd970'),
      brightBlue: v('--c12', '#7cc0f5'),
      brightMagenta: v('--c13', '#dcb0ff'),
      brightCyan: v('--c14', '#7ee8ef'),
      brightWhite: v('--c15', '#f2fbf6'),
    };
  }

  function applyTheme(name) {
    themeName = name;
    if (name === 'dark') {
      document.documentElement.removeAttribute('data-theme');
    } else {
      document.documentElement.setAttribute('data-theme', name);
    }
    store.set('webos.theme', name);

    const meta = document.querySelector('meta[name="theme-color"]');
    const bg = getComputedStyle(document.documentElement).getPropertyValue('--bg').trim();
    if (meta && bg) meta.setAttribute('content', bg);

    const palette = paletteFromCSS();
    sessions.forEach((s) => {
      s.term.options.theme = palette;
    });
  }

  applyTheme(themeName);

  function setFontSize(next) {
    fontSize = clamp(next, MIN_FONT, MAX_FONT);
    store.set('webos.font', String(fontSize));
    sessions.forEach((s) => {
      s.term.options.fontSize = fontSize;
      s.fit();
    });
  }

  // --- status --------------------------------------------------------------

  function setStatus(state, label) {
    els.connDot.className = 'dot ' + state;
    els.connLabel.textContent = label;
  }

  function showOffline(show, detail) {
    els.offline.classList.toggle('hidden', !show);
    if (detail) els.offlineDetail.textContent = detail;
  }

  // Only the session holding the keyboard drives the shared status bar. In the
  // desktop several sockets report at once, and without this the indicator
  // would flicker between whichever of them last changed state.
  function statusFrom(session, state, label) {
    if (session !== active) return;
    setStatus(state, label);
    if (state === 'online') showOffline(false);
  }

  // --- sessions ------------------------------------------------------------

  const decoder = new TextDecoder('utf-8');

  function socketURL() {
    const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
    return scheme + '//' + location.host + '/ws';
  }

  /*
   * One terminal bound to one shell.
   *
   * `hooks` lets the owner — classic mode or a desktop window — react without
   * this factory knowing which it is: onStatus for chrome, onCwd for a window
   * title, onClosed when the socket gives up for good.
   */
  function createSession(host, hooks) {
    hooks = hooks || {};

    const term = new Terminal({
      cursorBlink: true,
      cursorStyle: 'block',
      fontFamily: getComputedStyle(document.documentElement)
        .getPropertyValue('--font-mono')
        .trim(),
      fontSize: fontSize,
      lineHeight: 1.15,
      letterSpacing: 0,
      scrollback: 4000,
      // The server owns the cursor and the prompt; local echo would double
      // every keystroke and fight the line editor's redraws.
      convertEol: false,
      theme: paletteFromCSS(),
      screenReaderMode: false,
      allowTransparency: false,
    });

    const fit = new FitAddon.FitAddon();
    term.loadAddon(fit);
    term.open(host);

    const session = {
      term,
      host,
      ws: null,
      cwd: '/',
      lastReported: '',
      reconnectAttempt: 0,
      reconnectTimer: null,
      countdownTimer: null,
      manuallyClosed: false,
      everConnected: false,
      destroyed: false,
    };

    session.fit = function () {
      // A hidden or minimised host measures as zero, and fitting to that
      // leaves the terminal one column wide when it comes back.
      if (!host.isConnected || host.offsetParent === null) return;
      if (host.clientWidth < 8 || host.clientHeight < 8) return;
      try {
        fit.fit();
      } catch (_) {
        /* the host can be zero-sized mid-layout; the next resize catches it */
      }
      session.reportSize();
    };

    session.send = function (data) {
      if (session.ws && session.ws.readyState === WebSocket.OPEN) {
        session.ws.send(data);
        return true;
      }
      return false;
    };

    // Reports the terminal size, the way a real terminal signals SIGWINCH.
    //
    // Sent as a binary frame, on the same separate channel the server uses in
    // the other direction, so it can never be confused with typed input.
    // Without it the server lays every table out for an assumed width and
    // `help` in a narrow window wraps into unreadable ribbon.
    session.reportSize = function () {
      if (!session.ws || session.ws.readyState !== WebSocket.OPEN) return;
      const key = term.cols + 'x' + term.rows;
      if (key === session.lastReported) return; // nothing changed; stay quiet
      session.lastReported = key;
      session.ws.send(
        new TextEncoder().encode(JSON.stringify({ t: 'size', cols: term.cols, rows: term.rows }))
      );
    };

    session.focus = function () {
      active = session;
      term.focus();
      if (session.ws && session.ws.readyState === WebSocket.OPEN) {
        statusFrom(session, 'online', session.statusLabel || 'connected');
      } else {
        statusFrom(session, 'offline', 'disconnected');
      }
    };

    function handleControl(buffer) {
      let msg;
      try {
        msg = JSON.parse(decoder.decode(buffer));
      } catch (_) {
        return; // a malformed control frame is ignored, never executed
      }
      if (!msg || typeof msg.t !== 'string') return;

      switch (msg.t) {
        case 'matrix':
          startMatrix(typeof msg.ms === 'number' ? clamp(msg.ms, 500, 15000) : 6000);
          break;

        case 'bell':
          flash(host);
          break;

        case 'theme':
          // Only names this client already knows; the server cannot inject
          // arbitrary CSS through a theme name.
          if (THEMES.includes(msg.name)) applyTheme(msg.name);
          break;

        case 'stat':
          if (typeof msg.users === 'number') {
            const n = msg.users;
            session.statusLabel = n === 1 ? 'connected · 1 user' : `connected · ${n} users`;
            statusFrom(session, 'online', session.statusLabel);
          }
          break;

        case 'cwd':
          if (typeof msg.path === 'string') {
            session.cwd = msg.path;
            if (hooks.onCwd) hooks.onCwd(msg.path);
          }
          break;

        default:
          break; // unknown types are ignored so the server can add more
      }
    }

    session.connect = function () {
      if (session.destroyed) return;

      clearTimeout(session.reconnectTimer);
      clearInterval(session.countdownTimer);
      session.manuallyClosed = false;

      statusFrom(session, 'connecting', session.everConnected ? 'reconnecting' : 'connecting');

      try {
        session.ws = new WebSocket(socketURL());
      } catch (_) {
        scheduleReconnect();
        return;
      }

      // Control frames arrive as binary. Without this they would surface as
      // Blob objects, which need an async read before they can be inspected.
      session.ws.binaryType = 'arraybuffer';

      session.ws.onopen = () => {
        session.everConnected = true;
        session.reconnectAttempt = 0;
        session.statusLabel = 'connected';
        statusFrom(session, 'online', 'connected');
        session.lastReported = ''; // a new socket knows nothing about our size
        session.fit();
        session.reportSize();
        if (session === active) term.focus();
        if (hooks.onOpen) hooks.onOpen();
      };

      session.ws.onmessage = (event) => {
        if (typeof event.data === 'string') {
          term.write(event.data);
          return;
        }
        handleControl(event.data);
      };

      session.ws.onclose = () => {
        if (session.manuallyClosed || session.destroyed) return;
        statusFrom(session, 'offline', 'disconnected');
        scheduleReconnect();
      };

      session.ws.onerror = () => {
        // onclose always follows, and that is where reconnection is handled;
        // doing it here as well would schedule two overlapping attempts.
      };
    };

    // Exponential backoff with jitter.
    //
    // Without the jitter, every session dropped by a restart would come back
    // at the same instant, and the reconnect storm would be indistinguishable
    // from an attack — and would fall foul of the server's own per-IP limits.
    // With the desktop this matters more, not less: one person reconnecting
    // now means several sockets at once.
    function scheduleReconnect() {
      if (session.destroyed) return;

      session.reconnectAttempt += 1;
      const base = Math.min(1000 * Math.pow(1.6, session.reconnectAttempt - 1), 20000);
      const delay = Math.round(base * (0.7 + Math.random() * 0.6));

      let remaining = Math.ceil(delay / 1000);
      if (session === active) showOffline(true, `reconnecting in ${remaining}s…`);

      clearInterval(session.countdownTimer);
      session.countdownTimer = setInterval(() => {
        remaining -= 1;
        if (session !== active) return;
        showOffline(true, remaining > 0 ? `reconnecting in ${remaining}s…` : 'reconnecting…');
      }, 1000);

      session.reconnectTimer = setTimeout(session.connect, delay);
    }

    session.retry = function () {
      session.reconnectAttempt = 0;
      clearTimeout(session.reconnectTimer);
      clearInterval(session.countdownTimer);
      session.connect();
    };

    session.destroy = function () {
      session.destroyed = true;
      session.manuallyClosed = true;
      clearTimeout(session.reconnectTimer);
      clearInterval(session.countdownTimer);
      if (session.ws) {
        try {
          session.ws.close();
        } catch (_) {
          /* already gone */
        }
      }
      try {
        term.dispose();
      } catch (_) {
        /* xterm can throw if the host went away first */
      }
      sessions.delete(session);
      if (active === session) active = sessions.values().next().value || null;
    };

    term.onData((data) => {
      if (!session.send(data)) {
        // Typing into a dead socket should say so rather than silently vanish.
        if (session === active) showOffline(true, 'not connected');
      }
    });

    // Letters typed while Ctrl is latched become control characters, so
    // "ctrl" then "c" works with the on-screen keyboard as well as the bar.
    term.attachCustomKeyEventHandler((event) => {
      if (!ctrlArmed || event.type !== 'keydown') return true;
      if (event.key.length !== 1) return true;

      const code = event.key.toUpperCase().charCodeAt(0);
      if (code >= 64 && code < 128) {
        session.send(String.fromCharCode(code & 0x1f));
        setCtrlArmed(false);
        event.preventDefault();
        return false;
      }
      return true;
    });

    // Tapping the terminal focuses it, which is what raises the on-screen
    // keyboard. Skipped when text is selected, so copying still works.
    host.addEventListener('mousedown', () => {
      const selection = window.getSelection();
      if (selection && selection.toString().length > 0) return;
      session.focus();
    });

    sessions.add(session);
    if (!active) active = session;

    session.fit();
    session.connect();
    return session;
  }

  function flash(hostEl) {
    (hostEl || document.body).animate(
      [{ filter: 'brightness(1)' }, { filter: 'brightness(1.8)' }, { filter: 'brightness(1)' }],
      { duration: 160 }
    );
  }

  // --- matrix effect -------------------------------------------------------

  const canvas = els.matrix;
  const ctx = canvas.getContext('2d', { alpha: true });
  let matrixTimer = null;
  let matrixStop = null;
  let drops = [];
  let columnWidth = 16;

  const GLYPHS =
    'アァカサタナハマヤャラワガザダバパイィキシチニヒミリヰギジヂビピウゥクスツヌフムユュルグズブヅプ' +
    'エェケセテネヘメレゲゼデベペオォコソトノホモヨョロゴゾドボポヴッンABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  function sizeMatrix() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const rect = canvas.getBoundingClientRect();
    canvas.width = Math.max(1, Math.floor(rect.width * dpr));
    canvas.height = Math.max(1, Math.floor(rect.height * dpr));
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    columnWidth = fontSize + 2;
    const columns = Math.ceil(rect.width / columnWidth);
    drops = new Array(columns).fill(0).map(() => Math.random() * -40);
  }

  function drawMatrix() {
    const rect = canvas.getBoundingClientRect();
    const accent = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim();

    ctx.fillStyle = 'rgba(0,0,0,0.07)';
    ctx.fillRect(0, 0, rect.width, rect.height);
    ctx.fillStyle = accent || '#35d07f';
    ctx.font = columnWidth - 2 + 'px monospace';

    for (let i = 0; i < drops.length; i++) {
      const ch = GLYPHS.charAt((Math.random() * GLYPHS.length) | 0);
      ctx.fillText(ch, i * columnWidth, drops[i] * columnWidth);
      if (drops[i] * columnWidth > rect.height && Math.random() > 0.975) {
        drops[i] = 0;
      }
      drops[i]++;
    }
  }

  function startMatrix(durationMs) {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      return; // respect the setting rather than overriding it for an effect
    }

    sizeMatrix();
    canvas.classList.add('active');

    clearInterval(matrixTimer);
    clearTimeout(matrixStop);
    matrixTimer = setInterval(drawMatrix, 33);

    matrixStop = setTimeout(() => {
      canvas.classList.remove('active');
      // Keep drawing through the fade, then stop and release the canvas.
      setTimeout(() => {
        clearInterval(matrixTimer);
        matrixTimer = null;
        ctx.clearRect(0, 0, canvas.width, canvas.height);
      }, 700);
    }, durationMs);
  }

  // --- touch key bar -------------------------------------------------------

  // Decodes the escape notation used in the key bar's data-send attributes.
  function decodeKey(text) {
    return text
      .replace(/\\x1b/g, '\x1b')
      .replace(/\\e/g, '\x1b')
      .replace(/\\t/g, '\t')
      .replace(/\\r/g, '\r')
      .replace(/\\n/g, '\n');
  }

  let ctrlArmed = false;

  function setCtrlArmed(on) {
    ctrlArmed = on;
    els.ctrlKey.classList.toggle('armed', on);
  }

  // A touch keyboard has no Ctrl, Esc, Tab or arrows. Rather than a modifier
  // that has to be held, Ctrl latches: tap it, then tap the next key.
  els.keybar.addEventListener('click', (event) => {
    const button = event.target.closest('button');
    if (!button || !active) return;

    if (button.dataset.modifier === 'ctrl') {
      setCtrlArmed(!ctrlArmed);
      active.term.focus();
      return;
    }

    const raw = button.dataset.send;
    if (raw === undefined) return;

    let out = decodeKey(raw);

    if (ctrlArmed && out.length === 1) {
      const code = out.toUpperCase().charCodeAt(0);
      if (code >= 64 && code < 128) {
        out = String.fromCharCode(code & 0x1f); // Ctrl-A is 0x01, and so on
      }
      setCtrlArmed(false);
    }

    active.send(out);
    active.term.focus();
  });

  // --- chrome --------------------------------------------------------------

  // Every chrome button hands focus straight back to the terminal.
  //
  // A <button> stays focused after being activated, and a focused button
  // treats Enter as another press. Without this, tapping "A+" and then typing
  // a command meant the Enter at the end changed the font size again instead
  // of running anything — the terminal never saw the keystroke at all.
  function chromeButton(el, action) {
    if (!el) return;
    el.addEventListener('click', () => {
      action();
      el.blur();
      if (active) active.term.focus();
    });
  }

  chromeButton(els.retry, () => {
    if (active) active.retry();
  });
  chromeButton(els.fontIn, () => setFontSize(fontSize + 1));
  chromeButton(els.fontOut, () => setFontSize(fontSize - 1));
  chromeButton(els.theme, () => {
    applyTheme(THEMES[(THEMES.indexOf(themeName) + 1) % THEMES.length]);
    sessions.forEach((s) => s.fit());
  });

  // --- layout --------------------------------------------------------------

  let resizeTimer = null;
  function scheduleRefit() {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      sessions.forEach((s) => s.fit());
      if (matrixTimer) sizeMatrix();
      if (window.WebOSDesktop) window.WebOSDesktop.onViewportChange();
    }, 60);
  }

  window.addEventListener('resize', scheduleRefit);
  window.addEventListener('orientationchange', scheduleRefit);

  // On mobile the window does not resize when the virtual keyboard opens — the
  // visual viewport does. Without this the prompt ends up hidden behind the
  // keyboard.
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', scheduleRefit);
  }

  // Catches the container changing for reasons no event reports, such as the
  // key bar appearing.
  if (window.ResizeObserver) {
    new ResizeObserver(scheduleRefit).observe(els.termHost);
  }

  // A backgrounded tab can miss the close event entirely; re-check on return.
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible') return;
    sessions.forEach((s) => {
      s.fit();
      if (!s.ws || s.ws.readyState === WebSocket.CLOSED) s.retry();
    });
  });

  window.addEventListener('beforeunload', () => {
    sessions.forEach((s) => {
      s.manuallyClosed = true;
      if (s.ws) s.ws.close();
    });
  });

  // The key bar is for devices whose keyboard cannot send these keys at all.
  if (window.matchMedia('(hover: none) and (pointer: coarse)').matches) {
    els.keybar.classList.remove('hidden');
    els.keybar.classList.add('available');
  }

  // --- modes ---------------------------------------------------------------

  let classicSession = null;
  let mode = store.get('webos.mode', 'classic') === 'desktop' ? 'desktop' : 'classic';

  function enterClassic() {
    mode = 'classic';
    store.set('webos.mode', mode);
    document.documentElement.setAttribute('data-mode', 'classic');
    if (window.WebOSDesktop) window.WebOSDesktop.stop();

    if (!classicSession || classicSession.destroyed) {
      classicSession = createSession(els.classicHost, {});
      classicSession.term.writeln('\x1b[90mWebOS terminal — establishing link…\x1b[0m');
    }
    classicSession.focus();
    scheduleRefit();
  }

  function enterDesktop() {
    if (!window.WebOSDesktop) return enterClassic();

    mode = 'desktop';
    store.set('webos.mode', mode);
    document.documentElement.setAttribute('data-mode', 'desktop');

    // The classic session is closed rather than hidden: leaving it open would
    // keep a shell — and a connection slot — that nothing on screen can reach.
    if (classicSession) {
      classicSession.destroy();
      classicSession = null;
      els.classicHost.innerHTML = '';
    }

    window.WebOSDesktop.start();
    scheduleRefit();
  }

  chromeButton(els.mode, () => (mode === 'desktop' ? enterClassic() : enterDesktop()));

  // Exposed for desktop.js, which owns the windows but not the connections.
  window.WebOS = {
    createSession,
    setActive: (s) => {
      active = s;
      if (s) s.focus();
    },
    getActive: () => active,
    refitAll: () => sessions.forEach((s) => s.fit()),
    store,
    fontSize: () => fontSize,
    showOffline,
    setStatus,
  };

  // --- boot ----------------------------------------------------------------

  if (mode === 'desktop' && window.WebOSDesktop) {
    enterDesktop();
  } else {
    enterClassic();
  }

  if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => {
      navigator.serviceWorker.register('/sw.js').catch(() => {
        /* offline support is optional */
      });
    });
  }
})();
