"""Drives the desktop in a browser with Playwright.

Not part of `make test-integration`: it needs a browser and Playwright, which
the deployment host is not required to have. Run it by hand against a local
server when the front end changes.

    WEBOS_PORT=47999 WEBOS_DATA_DIR=/tmp/webos-test ./bin/webos_server &
    python3 tests/browser/desktop.py

Screenshots land in the working directory, which is usually what you actually
want to look at after a layout change.
"""
import os

from playwright.sync_api import sync_playwright
import time

URL = os.environ.get("WEBOS_URL", "http://127.0.0.1:47999/")
errs = []

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1280, "height": 820})
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.on("console", lambda m: errs.append("console: " + m.text) if m.type == "error" else None)
    pg.goto(URL, wait_until="networkidle")
    pg.wait_for_timeout(2000)

    print("== classic mode boots ==")
    print("  terminal rendered:", pg.locator(".xterm-screen").count() > 0)
    print("  desktop hidden:", pg.locator("#desktop.hidden").count() == 1)

    # Switch to desktop
    pg.click("#btn-mode")
    pg.wait_for_timeout(2500)
    print("== desktop mode ==")
    print("  windows:", pg.locator(".window").count())
    print("  taskbar items:", pg.locator(".task-item").count())
    print("  terminals:", pg.locator(".window .xterm-screen").count())

    # Type into the first window
    pg.click(".window .xterm-screen")
    pg.keyboard.type("echo window-one"); pg.keyboard.press("Enter")
    pg.wait_for_timeout(900)

    # Open a second window
    pg.click("#btn-new-window")
    pg.wait_for_timeout(2200)
    print("  after new window:", pg.locator(".window").count(), "windows")

    pg.click(".window:last-child .xterm-screen")
    pg.keyboard.type("cd /tmp && echo window-two"); pg.keyboard.press("Enter")
    pg.wait_for_timeout(1200)

    titles = pg.locator(".window-title").all_inner_texts()
    print("  titles:", titles)

    body = pg.inner_text("body")
    print("  both shells ran:", "window-one" in body and "window-two" in body)
    print("  they are separate shells:", body.count("window-one") >= 1)

    pg.screenshot(path="desk-two.png")

    # Drag the second window
    bar = pg.locator(".window:last-child .window-bar")
    box = bar.bounding_box()
    pg.mouse.move(box["x"] + 60, box["y"] + 12)
    pg.mouse.down()
    pg.mouse.move(box["x"] + 260, box["y"] + 160, steps=12)
    pg.mouse.up()
    pg.wait_for_timeout(500)
    after = pg.locator(".window:last-child").bounding_box()
    print("  dragged to:", round(after["x"]), round(after["y"]))

    # Minimise / restore via taskbar
    pg.click(".window:last-child .window-btn.min")
    pg.wait_for_timeout(500)
    print("  minimised hidden:", pg.locator(".window.minimized").count() == 1)
    pg.locator(".task-item").last.click()
    pg.wait_for_timeout(700)
    print("  restored:", pg.locator(".window.minimized").count() == 0)

    # Maximise
    pg.click(".window:last-child .window-btn.max")
    pg.wait_for_timeout(700)
    print("  maximised:", pg.locator(".window.maximized").count() == 1)
    pg.click(".window:last-child .window-btn.max")
    pg.wait_for_timeout(500)

    # Close one
    pg.click(".window:last-child .window-btn.close")
    pg.wait_for_timeout(800)
    print("  after close:", pg.locator(".window").count(), "windows")

    pg.screenshot(path="desk-final.png")
    b.close()

print("PAGE ERRORS:", errs if errs else "none")
