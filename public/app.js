/* ---------------------------------------------------------------------------
   WebOS terminal client
   ---------------------------------------------------------------------------
   Two channels share one socket:

     text frames   terminal output, written straight through to xterm
     binary frames control messages as JSON

   That split matters. Effects used to be triggered by the server embedding
   "___MATRIX_START___" in the output stream and this file scanning for it,
   which meant anyone could fire the effect on every screen by typing
   `wall ___MATRIX_START___`, and any file containing that text did the same
   when displayed. Terminal output is user data; a control channel made of user
   data is not a control channel. Binary frames cannot be produced by anything
   a user types.
--------------------------------------------------------------------------- */
'use strict';

(function () {
  const $ = (id) => document.getElementById(id);

  const els = {
    termHost: $('terminal'),
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

  // Declared up here, not where they are used, because initialisation reads
  // them before it reaches those sections: applyTheme runs before the terminal
  // exists, and refit() reports the size before a socket exists. A `let` or
  // `const` further down would be in its temporal dead zone at that moment and
  // throw, taking the whole script with it.
  let term = null;
  let ws = null;
  let lastReported = '';

  const MIN_FONT = 10;
  const MAX_FONT = 22;

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

  function clamp(n, lo, hi) {
    return Math.min(hi, Math.max(lo, n));
  }

  // --- terminal ------------------------------------------------------------

  // Reads the palette back out of CSS so the terminal and the page chrome can
  // never disagree about what the current theme looks like.
  function paletteFromCSS() {
    const css = getComputedStyle(document.documentElement);
    const v = (name, fallback) => (css.getPropertyValue(name) || fallback).trim();

    const bg = v('--bg', '#0b0f10');
    const fg = v('--fg', '#c8d3d5');
    const accent = v('--accent', '#35d07f');
    const dim = v('--fg-dim', '#6b7d80');

    return {
      background: bg,
      foreground: fg,
      cursor: accent,
      cursorAccent: bg,
      selectionBackground: dim + '55',
      black: bg,
      brightBlack: dim,
      white: fg,
      brightWhite: '#ffffff',
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
    const bg = getComputedStyle(document.documentElement)
      .getPropertyValue('--bg')
      .trim();
    if (meta && bg) meta.setAttribute('content', bg);

    if (term) term.options.theme = paletteFromCSS();
  }

  applyTheme(themeName);

  term = new Terminal({
    cursorBlink: true,
    cursorStyle: 'block',
    fontFamily: getComputedStyle(document.documentElement)
      .getPropertyValue('--font-mono')
      .trim(),
    fontSize: fontSize,
    lineHeight: 1.15,
    letterSpacing: 0,
    scrollback: 4000,
    // The server owns the cursor and the prompt; local echo would double every
    // keystroke and fight the line editor's redraws.
    convertEol: false,
    theme: paletteFromCSS(),
    // Screen-reader users get a live region with the last lines of output
    // instead of a canvas they cannot read.
    screenReaderMode: false,
    allowTransparency: false,
  });

  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open(els.termHost);

  function refit() {
    try {
      fit.fit();
    } catch (_) {
      /* the host can be zero-sized mid-layout; the next resize will catch it */
    }
    reportSize();
  }

  refit();

  function setFontSize(next) {
    fontSize = clamp(next, MIN_FONT, MAX_FONT);
    term.options.fontSize = fontSize;
    store.set('webos.font', String(fontSize));
    refit();
  }

  // --- connection ----------------------------------------------------------

  let reconnectAttempt = 0;
  let reconnectTimer = null;
  let countdownTimer = null;
  let manuallyClosed = false;
  let everConnected = false;

  function setStatus(state, label) {
    els.connDot.className = 'dot ' + state;
    els.connLabel.textContent = label;
  }

  function showOffline(show, detail) {
    els.offline.classList.toggle('hidden', !show);
    if (detail) els.offlineDetail.textContent = detail;
  }

  function socketURL() {
    const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
    return scheme + '//' + location.host + '/ws';
  }

  function connect() {
    clearTimeout(reconnectTimer);
    clearInterval(countdownTimer);
    manuallyClosed = false;

    setStatus('connecting', everConnected ? 'reconnecting' : 'connecting');

    try {
      ws = new WebSocket(socketURL());
    } catch (err) {
      scheduleReconnect();
      return;
    }

    // Control frames arrive as binary. Without this they would surface as Blob
    // objects, which need an async read before they can be inspected.
    ws.binaryType = 'arraybuffer';

    ws.onopen = () => {
      everConnected = true;
      reconnectAttempt = 0;
      setStatus('online', 'connected');
      showOffline(false);
      lastReported = ''; // a new socket knows nothing about our size
      refit();
      reportSize();
      term.focus();
    };

    ws.onmessage = (event) => {
      if (typeof event.data === 'string') {
        term.write(event.data);
        return;
      }
      handleControl(event.data);
    };

    ws.onclose = () => {
      if (manuallyClosed) return;
      setStatus('offline', 'disconnected');
      scheduleReconnect();
    };

    ws.onerror = () => {
      // onclose always follows, and that is where reconnection is handled;
      // doing it here as well would schedule two overlapping attempts.
    };
  }

  // Exponential backoff with jitter.
  //
  // Without the jitter, every session dropped by a restart would come back at
  // the same instant, and the reconnect storm would be indistinguishable from
  // an attack — and would fall foul of the server's own per-IP limits.
  function scheduleReconnect() {
    reconnectAttempt += 1;
    const base = Math.min(1000 * Math.pow(1.6, reconnectAttempt - 1), 20000);
    const delay = Math.round(base * (0.7 + Math.random() * 0.6));

    let remaining = Math.ceil(delay / 1000);
    showOffline(true, `reconnecting in ${remaining}s…`);

    clearInterval(countdownTimer);
    countdownTimer = setInterval(() => {
      remaining -= 1;
      if (remaining > 0) {
        showOffline(true, `reconnecting in ${remaining}s…`);
      } else {
        clearInterval(countdownTimer);
        showOffline(true, 'reconnecting…');
      }
    }, 1000);

    reconnectTimer = setTimeout(connect, delay);
  }

  function send(data) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(data);
      return true;
    }
    return false;
  }

  // Reports the terminal size, the way a real terminal signals SIGWINCH.
  //
  // Sent as a binary frame, on the same separate channel the server uses in
  // the other direction, so it can never be confused with typed input. Without
  // it the server lays every table out for an assumed width and `help` on a
  // phone wraps into unreadable ribbon.
  function reportSize() {
    if (!term || !ws || ws.readyState !== WebSocket.OPEN) return;

    const key = term.cols + 'x' + term.rows;
    if (key === lastReported) return; // nothing changed; stay quiet
    lastReported = key;

    const json = JSON.stringify({ t: 'size', cols: term.cols, rows: term.rows });
    ws.send(new TextEncoder().encode(json));
  }

  // --- control channel -----------------------------------------------------

  const decoder = new TextDecoder('utf-8');

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
        flash();
        break;

      case 'theme':
        // Only names this client already knows; the server cannot inject
        // arbitrary CSS through a theme name.
        if (THEMES.includes(msg.name)) applyTheme(msg.name);
        break;

      case 'stat':
        if (typeof msg.users === 'number' && ws && ws.readyState === WebSocket.OPEN) {
          const n = msg.users;
          setStatus('online', n === 1 ? 'connected · 1 user' : `connected · ${n} users`);
        }
        break;

      default:
        break; // unknown types are ignored so the server can add more
    }
  }

  function flash() {
    els.termHost.animate(
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
    const accent = getComputedStyle(document.documentElement)
      .getPropertyValue('--accent')
      .trim();

    ctx.fillStyle = 'rgba(0,0,0,0.07)';
    ctx.fillRect(0, 0, rect.width, rect.height);
    ctx.fillStyle = accent || '#35d07f';
    ctx.font = columnWidth - 2 + 'px ' + term.options.fontFamily;

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

  // --- input ---------------------------------------------------------------

  term.onData((data) => {
    if (!send(data)) {
      // Typing into a dead socket should say so rather than silently vanish.
      showOffline(true, 'not connected');
    }
  });

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
    if (!button) return;

    if (button.dataset.modifier === 'ctrl') {
      setCtrlArmed(!ctrlArmed);
      term.focus();
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

    send(out);
    term.focus();
  });

  // Letters typed while Ctrl is latched become control characters too, so
  // "ctrl" then "c" works with the on-screen keyboard as well as the bar.
  term.attachCustomKeyEventHandler((event) => {
    if (!ctrlArmed || event.type !== 'keydown') return true;
    if (event.key.length !== 1) return true;

    const code = event.key.toUpperCase().charCodeAt(0);
    if (code >= 64 && code < 128) {
      send(String.fromCharCode(code & 0x1f));
      setCtrlArmed(false);
      event.preventDefault();
      return false;
    }
    return true;
  });

  // Tapping anywhere in the terminal area focuses it, which is what raises the
  // on-screen keyboard. Skipped when text is selected, so copying still works.
  els.termHost.addEventListener('click', () => {
    const selection = window.getSelection();
    if (selection && selection.toString().length > 0) return;
    term.focus();
  });

  // Every chrome button hands focus straight back to the terminal.
  //
  // A <button> stays focused after being activated, and a focused button
  // treats Enter as another press. Without this, tapping "A+" and then typing
  // a command meant the Enter at the end changed the font size again instead
  // of running anything — the terminal never saw the keystroke at all.
  function chromeButton(el, action) {
    el.addEventListener('click', () => {
      action();
      el.blur();
      term.focus();
    });
  }

  chromeButton(els.retry, () => {
    reconnectAttempt = 0;
    clearTimeout(reconnectTimer);
    clearInterval(countdownTimer);
    connect();
  });

  chromeButton(els.fontIn, () => setFontSize(fontSize + 1));
  chromeButton(els.fontOut, () => setFontSize(fontSize - 1));

  chromeButton(els.theme, () => {
    const next = THEMES[(THEMES.indexOf(themeName) + 1) % THEMES.length];
    applyTheme(next);
    refit();
  });

  // --- layout --------------------------------------------------------------

  let resizeTimer = null;
  function scheduleRefit() {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      refit();
      if (matrixTimer) sizeMatrix();
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
    refit();
    if (!ws || ws.readyState === WebSocket.CLOSED) {
      reconnectAttempt = 0;
      connect();
    }
  });

  window.addEventListener('beforeunload', () => {
    manuallyClosed = true;
    if (ws) ws.close();
  });

  // The key bar is for devices whose keyboard cannot send these keys at all.
  if (window.matchMedia('(hover: none) and (pointer: coarse)').matches) {
    els.keybar.classList.remove('hidden');
    els.keybar.classList.add('available');
    scheduleRefit();
  }

  // --- boot ----------------------------------------------------------------

  term.writeln('\x1b[90mWebOS terminal — establishing link…\x1b[0m');
  connect();

  if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => {
      navigator.serviceWorker.register('/sw.js').catch(() => {
        /* offline support is optional */
      });
    });
  }
})();
