/*
 * The desktop.
 *
 * A window manager over the sessions app.js creates. Each window holds one
 * terminal, which is one shell on the server — the same relationship a real
 * desktop has, where opening a second terminal gives you a second shell rather
 * than a second view of the first.
 *
 * This file owns geometry, stacking and the taskbar. It never touches a socket:
 * everything to do with a connection stays in app.js, reached through
 * window.WebOS.
 */
(function () {
  const $ = (id) => document.getElementById(id);

  const root = $('desktop');
  const surface = $('desktop-surface');
  const taskbar = $('taskbar-items');
  const btnNew = $('btn-new-window');

  if (!root || !surface || !taskbar) return;

  // Each window is a session, and a session is a connection. The server
  // permits several per address, but a person with a dozen terminals open is
  // holding a dozen shells — this is the point where that stops being useful.
  const MAX_WINDOWS = 6;

  const TITLEBAR_H = 30;
  const MIN_W = 260;
  const MIN_H = 160;

  const windows = [];
  let seq = 0;
  let topZ = 10;
  let running = false;

  // Below this the screen cannot hold two windows side by side, so they are
  // shown one at a time and the taskbar becomes the way to switch — which is
  // what a phone does anyway.
  function isNarrow() {
    return window.matchMedia('(max-width: 720px)').matches;
  }

  // --- persistence ---------------------------------------------------------
  //
  // Only geometry is saved. Restoring the *shells* is not possible — they live
  // on the server and are gone the moment the socket closes — so a reload
  // reopens the same arrangement of windows with fresh sessions in them.

  function saveLayout() {
    if (!running) return;
    const state = windows.map((w) => ({
      x: w.x,
      y: w.y,
      w: w.w,
      h: w.h,
      max: w.maximized,
      min: w.minimized,
    }));
    WebOS.store.set('webos.desktop.layout', JSON.stringify(state));
  }

  function loadLayout() {
    try {
      const raw = WebOS.store.get('webos.desktop.layout', '');
      const parsed = raw ? JSON.parse(raw) : null;
      return Array.isArray(parsed) ? parsed.slice(0, MAX_WINDOWS) : null;
    } catch (_) {
      return null; // a corrupt layout is not worth failing to boot over
    }
  }

  // --- geometry ------------------------------------------------------------

  function bounds() {
    const r = surface.getBoundingClientRect();
    return { w: r.width, h: r.height };
  }

  function cascade(index) {
    const b = bounds();
    const w = Math.min(720, Math.max(MIN_W, Math.round(b.w * 0.62)));
    const h = Math.min(460, Math.max(MIN_H, Math.round(b.h * 0.66)));
    const step = 28;
    // Wrap the cascade rather than letting the fifth window walk off the
    // bottom-right corner of the screen.
    const offset = (index % 5) * step;
    return {
      x: Math.min(offset + 16, Math.max(0, b.w - w)),
      y: Math.min(offset + 12, Math.max(0, b.h - h)),
      w,
      h,
    };
  }

  // Keeps a window's title bar reachable. A window dragged mostly off-screen,
  // or left where a smaller viewport can no longer reach it, becomes
  // impossible to move back — so the position is clamped whenever it changes.
  function clampToSurface(win) {
    const b = bounds();
    win.w = Math.max(MIN_W, Math.min(win.w, b.w));
    win.h = Math.max(MIN_H, Math.min(win.h, b.h));
    win.x = Math.max(-(win.w - 80), Math.min(win.x, b.w - 80));
    win.y = Math.max(0, Math.min(win.y, b.h - TITLEBAR_H));
  }

  function applyGeometry(win) {
    if (isNarrow() || win.maximized) {
      win.el.style.left = '0px';
      win.el.style.top = '0px';
      win.el.style.width = '100%';
      win.el.style.height = '100%';
      return;
    }
    clampToSurface(win);
    win.el.style.left = win.x + 'px';
    win.el.style.top = win.y + 'px';
    win.el.style.width = win.w + 'px';
    win.el.style.height = win.h + 'px';
  }

  // --- stacking ------------------------------------------------------------

  function focusWindow(win) {
    if (!win || win.minimized) return;

    topZ += 1;
    win.el.style.zIndex = String(topZ);

    windows.forEach((w) => {
      w.el.classList.toggle('focused', w === win);
      if (w.taskButton) w.taskButton.classList.toggle('active', w === win);
    });

    // On a narrow screen only the focused window is on screen at all.
    if (isNarrow()) {
      windows.forEach((w) => w.el.classList.toggle('hidden-window', w !== win));
    }

    WebOS.setActive(win.session);
    win.session.fit();
  }

  // --- window construction -------------------------------------------------

  function makeWindow(geometry) {
    if (windows.length >= MAX_WINDOWS) return null;

    seq += 1;
    const id = seq;

    const el = document.createElement('section');
    el.className = 'window';
    el.setAttribute('role', 'dialog');
    el.setAttribute('aria-label', 'Terminal ' + id);

    const bar = document.createElement('header');
    bar.className = 'window-bar';

    const title = document.createElement('span');
    title.className = 'window-title';
    title.textContent = 'terminal ' + id;

    const controls = document.createElement('div');
    controls.className = 'window-controls';

    const mkBtn = (cls, label, glyph) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'window-btn ' + cls;
      b.title = label;
      b.setAttribute('aria-label', label);
      b.textContent = glyph;
      controls.appendChild(b);
      return b;
    };

    const btnMin = mkBtn('min', 'Minimise', '–');
    const btnMax = mkBtn('max', 'Maximise', '□');
    const btnClose = mkBtn('close', 'Close', '×');

    bar.appendChild(title);
    bar.appendChild(controls);

    const body = document.createElement('div');
    body.className = 'window-body';

    const grip = document.createElement('div');
    grip.className = 'window-grip';
    grip.setAttribute('aria-hidden', 'true');

    el.appendChild(bar);
    el.appendChild(body);
    el.appendChild(grip);
    surface.appendChild(el);

    const geo = geometry || cascade(windows.length);
    const win = {
      id,
      el,
      body,
      title,
      x: geo.x,
      y: geo.y,
      w: geo.w,
      h: geo.h,
      maximized: !!geo.max,
      minimized: false,
      session: null,
      taskButton: null,
    };

    applyGeometry(win);

    win.session = WebOS.createSession(body, {
      onCwd: (path) => {
        // The title follows the shell, which is what makes several windows
        // tellable apart without reading their contents. The taskbar keeps the
        // number in front of the path: a button reading only "/tmp" says where
        // a window is but not which one it is.
        title.textContent = 'terminal ' + id + ' — ' + path;
        if (win.taskButton) {
          win.taskButton.textContent = path === '/' ? 'terminal ' + id : id + ': ' + path;
        }
      },
    });

    // --- interaction ---
    el.addEventListener('pointerdown', () => focusWindow(win), true);

    btnClose.addEventListener('click', (e) => {
      e.stopPropagation();
      closeWindow(win);
    });

    btnMin.addEventListener('click', (e) => {
      e.stopPropagation();
      minimiseWindow(win);
    });

    btnMax.addEventListener('click', (e) => {
      e.stopPropagation();
      win.maximized = !win.maximized;
      el.classList.toggle('maximized', win.maximized);
      applyGeometry(win);
      win.session.fit();
      saveLayout();
    });

    bar.addEventListener('dblclick', () => {
      win.maximized = !win.maximized;
      el.classList.toggle('maximized', win.maximized);
      applyGeometry(win);
      win.session.fit();
      saveLayout();
    });

    makeDraggable(win, bar);
    makeResizable(win, grip);

    windows.push(win);
    addTaskButton(win);
    focusWindow(win);
    saveLayout();
    return win;
  }

  function closeWindow(win) {
    win.session.destroy();
    win.el.remove();
    if (win.taskButton) win.taskButton.remove();

    const i = windows.indexOf(win);
    if (i >= 0) windows.splice(i, 1);

    // A desktop with no windows has no way back to a shell, so the last one
    // closed immediately opens a fresh one rather than leaving a dead screen.
    if (windows.length === 0) {
      makeWindow();
      return;
    }
    focusWindow(windows[windows.length - 1]);
    saveLayout();
  }

  function minimiseWindow(win) {
    win.minimized = true;
    win.el.classList.add('minimized');
    if (win.taskButton) win.taskButton.classList.remove('active');

    const next = windows.filter((w) => !w.minimized).pop();
    if (next) focusWindow(next);
    saveLayout();
  }

  function restoreWindow(win) {
    win.minimized = false;
    win.el.classList.remove('minimized');
    focusWindow(win);
    win.session.fit();
    saveLayout();
  }

  // --- taskbar -------------------------------------------------------------

  function addTaskButton(win) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'task-item';
    b.textContent = 'terminal ' + win.id;
    b.title = 'Show terminal ' + win.id;
    b.addEventListener('click', () => {
      if (win.minimized) {
        restoreWindow(win);
      } else if (WebOS.getActive() === win.session && !isNarrow()) {
        minimiseWindow(win); // clicking the focused window's button hides it
      } else {
        focusWindow(win);
      }
    });
    taskbar.appendChild(b);
    win.taskButton = b;
  }

  // --- dragging and resizing -----------------------------------------------
  //
  // Pointer events rather than mouse events, so a touch drag works with the
  // same code. Capture keeps the drag alive when the pointer leaves the bar,
  // which is otherwise very easy to do while moving quickly.

  function makeDraggable(win, handle) {
    let startX = 0;
    let startY = 0;
    let originX = 0;
    let originY = 0;
    let dragging = false;

    handle.addEventListener('pointerdown', (e) => {
      if (e.target.closest('.window-btn')) return; // the buttons are not a handle
      if (isNarrow() || win.maximized) return;

      dragging = true;
      startX = e.clientX;
      startY = e.clientY;
      originX = win.x;
      originY = win.y;
      handle.setPointerCapture(e.pointerId);
      win.el.classList.add('dragging');
      e.preventDefault();
    });

    handle.addEventListener('pointermove', (e) => {
      if (!dragging) return;
      win.x = originX + (e.clientX - startX);
      win.y = originY + (e.clientY - startY);
      applyGeometry(win);
    });

    const end = (e) => {
      if (!dragging) return;
      dragging = false;
      win.el.classList.remove('dragging');
      try {
        handle.releasePointerCapture(e.pointerId);
      } catch (_) {
        /* the capture may already have been lost */
      }
      saveLayout();
    };

    handle.addEventListener('pointerup', end);
    handle.addEventListener('pointercancel', end);
  }

  function makeResizable(win, grip) {
    let startX = 0;
    let startY = 0;
    let originW = 0;
    let originH = 0;
    let sizing = false;

    grip.addEventListener('pointerdown', (e) => {
      if (isNarrow() || win.maximized) return;
      sizing = true;
      startX = e.clientX;
      startY = e.clientY;
      originW = win.w;
      originH = win.h;
      grip.setPointerCapture(e.pointerId);
      e.preventDefault();
      e.stopPropagation();
    });

    grip.addEventListener('pointermove', (e) => {
      if (!sizing) return;
      win.w = originW + (e.clientX - startX);
      win.h = originH + (e.clientY - startY);
      applyGeometry(win);
    });

    const end = (e) => {
      if (!sizing) return;
      sizing = false;
      try {
        grip.releasePointerCapture(e.pointerId);
      } catch (_) {
        /* already released */
      }
      // Fitted once at the end rather than on every move: reflowing a terminal
      // per pointer event is what makes a resize feel like treacle.
      win.session.fit();
      saveLayout();
    };

    grip.addEventListener('pointerup', end);
    grip.addEventListener('pointercancel', end);
  }

  // --- lifecycle -----------------------------------------------------------

  function start() {
    if (running) return;
    running = true;
    root.classList.remove('hidden');

    const saved = loadLayout();
    if (saved && saved.length) {
      saved.forEach((geo) => makeWindow(geo));
      // A layout where everything was minimised would restore to a blank
      // screen with no obvious way back.
      if (windows.every((w) => w.minimized)) restoreWindow(windows[0]);
    } else {
      makeWindow();
    }
  }

  function stop() {
    running = false;
    root.classList.add('hidden');
    windows.slice().forEach((w) => {
      w.session.destroy();
      w.el.remove();
      if (w.taskButton) w.taskButton.remove();
    });
    windows.length = 0;
  }

  function onViewportChange() {
    if (!running) return;
    windows.forEach((w) => {
      applyGeometry(w);
      if (!w.minimized) w.session.fit();
    });
    // Crossing the narrow threshold changes what "visible" means, so the
    // focused window has to be re-asserted.
    const focused = windows.find((w) => w.session === WebOS.getActive());
    if (focused) focusWindow(focused);
  }

  if (btnNew) {
    btnNew.addEventListener('click', () => {
      const win = makeWindow();
      if (!win) {
        // Silence here would read as a broken button.
        btnNew.classList.add('refused');
        setTimeout(() => btnNew.classList.remove('refused'), 600);
      }
    });
  }

  window.WebOSDesktop = { start, stop, onViewportChange };
})();
