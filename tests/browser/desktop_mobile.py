"""Drives the desktop on a phone viewport with Playwright.

Not part of `make test-integration`: it needs a browser and Playwright, which
the deployment host is not required to have. Run it by hand against a local
server when the front end changes.

    WEBOS_PORT=47999 WEBOS_DATA_DIR=/tmp/webos-test ./bin/webos_server &
    python3 tests/browser/desktop_mobile.py

Screenshots land in the working directory, which is usually what you actually
want to look at after a layout change.
"""
import os

from playwright.sync_api import sync_playwright

URL = os.environ.get("WEBOS_URL", "http://127.0.0.1:47999/")
errs = []
with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(**p.devices["iPhone 13"])
    pg = ctx.new_page()
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.on("console", lambda m: errs.append("console: " + m.text) if m.type == "error" else None)
    pg.goto(URL, wait_until="networkidle")
    pg.wait_for_timeout(2000)

    # localStorage still says classic from a fresh profile; switch over.
    pg.click("#btn-mode")
    pg.wait_for_timeout(2500)

    print("windows:", pg.locator(".window").count())
    print("grip hidden on touch:", pg.locator(".window-grip").first.is_visible() is False)

    pg.click("#btn-new-window")
    pg.wait_for_timeout(2200)
    print("after new:", pg.locator(".window").count(), "windows")
    # Only the focused one is on screen at a phone width.
    print("visible windows:", pg.locator(".window:not(.hidden-window):not(.minimized)").count())
    print("taskbar items:", pg.locator(".task-item").count())

    overflow = pg.evaluate(
        "() => document.documentElement.scrollWidth - document.documentElement.clientWidth")
    print("horizontal overflow:", overflow)

    # Switch windows from the taskbar.
    pg.locator(".task-item").first.click()
    pg.wait_for_timeout(800)
    print("still one visible after switching:",
          pg.locator(".window:not(.hidden-window):not(.minimized)").count())

    pg.screenshot(path="desk-phone.png")
    ctx.close(); b.close()

print("PAGE ERRORS:", errs if errs else "none")
