#!/usr/bin/env python3
# pack.py — bundle the web wallet into ONE double-clickable HTML file.
#
# Output: dist/axiom-wallet.html   (runs from file:// — no server needed)
#
# The page imports nothing and fetches nothing: it is pure classic scripts
# (no ES modules), so double-clicking the file opens a working wallet.
#
#   - wasm-bindgen glue is built with the `no-modules` target (global
#     `wasm_bindgen`), inlined verbatim as a classic <script>.
#   - the three standalone web modules (transport/kiddo/genesis) are each
#     wrapped in an IIFE with their `export` keyword stripped, exposing their
#     public functions on `window`.
#   - the page's app script is de-moduled: the dynamic import()s are dropped
#     (their symbols are globals now), wasm + Core ELF are base64-inlined and
#     handed to init()/setup() as bytes, and the whole body is wrapped in an
#     async IIFE (classic scripts have no top-level await).
#
# Prereqs (run once after any code change):
#   wasm-pack build --release --target no-modules --out-dir pkg-nomod \
#       --out-name axiom_sdk_wasm
#   cp ../../core/artifacts/axiom-core.elf pkg-nomod/axiom-core.elf
# then: python3 pack.py
#
# NOTE on file://: the wallet still talks to the env over WebSocket; ws://
# from a file:// page (origin "null") is allowed by browsers. localStorage
# on file:// is shared across all file:// pages on the machine — fine for a
# single hand-off wallet.

import base64
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
WEB = HERE / "web"
PKG = HERE / "pkg-nomod"  # the no-modules build
OUT_DIR = HERE / "dist"
OUT = OUT_DIR / "axiom-wallet.html"

# Each web module → the public functions it must expose as window globals.
WEB_MODULES = [
    ("transport.js", ["makeTotTransport", "totConfigFrom"]),
    ("kiddo.js", ["pop3FetchAll", "fatmamaRegister", "kiddoReceiveCycle"]),
    ("genesis.js", ["claimGenesis", "redeem", "claimAndRedeem", "send", "heal", "burnScars", "halReanchor", "halComplete", "recall", "recallComplete", "resumeSend"]),
    ("vault.js", ["VAULT"]),  # app-layer at-rest crypto; references global `nacl` (inlined into markup)
]

# The classic <script src> in the markup that the single file must inline (file://
# can't fetch a sibling). Verified present + replaced in main() — fail loud on drift.
NACL_TAG = '<script src="./nacl.min.js"></script>'

# App-script rewrites: drop the module plumbing, point at the bundled globals
# + embedded bytes. (old, new) — every `old` must be present or we fail loud.
APP_REWRITES = [
    ("const _mod = await import('../pkg/axiom_sdk_wasm.js?v=' + V);",
     "// (bundled) wasm-bindgen no-modules glue is the global `wasm_bindgen`"),
    ("const { setup, getCoreId, canonicalCoreId, Wallet, formatAxc, formatLdollarShort, sdkVersion, atomsPerAxc, kuaikuaiArt } = _mod;",
     "const { setup, getCoreId, canonicalCoreId, Wallet, formatAxc, formatLdollarShort, sdkVersion, atomsPerAxc, kuaikuaiArt } = wasm_bindgen;"),
    ("const _init = _mod.default;",
     "const _init = wasm_bindgen;"),
    ("const { fatmamaRegister, kiddoReceiveCycle } = await import('./kiddo.js?v=' + V);",
     "// fatmamaRegister, kiddoReceiveCycle: bundled globals"),
    ("const { claimGenesis, redeem, send, sendWithScarPasscode, heal, burnScars, halReanchor, halComplete, recall, recallComplete, resumeSend } = await import('./genesis.js?v=' + V);",
     "// claimGenesis, redeem, send, sendWithScarPasscode, heal, burnScars, halReanchor, halComplete, recall, recallComplete, resumeSend: bundled globals"),
    ("const { makeTotTransport, totConfigFrom } = await import('./transport.js?v=' + V);",
     "// makeTotTransport, totConfigFrom: bundled globals"),
    ("const { VAULT } = await import('./vault.js?v=' + V);",
     "// VAULT: bundled global (window.VAULT)"),
    ("new URL('../pkg/axiom_sdk_wasm_bg.wasm?v=' + V, import.meta.url)", "__WASM_BYTES"),
    ("new Uint8Array(await (await fetch('../pkg/axiom-core.elf?v=' + V)).arrayBuffer())", "__ELF_BYTES"),
    # Off-thread CL signing in the single file: a classic Blob worker built from
    # the inlined no-modules glue + harness (see __CL_WORKER_SRC in the prelude),
    # handed the wasm bytes directly since a file:// Blob worker can't fetch.
    ("function makeClWorker() { return new Worker('./cl-worker.js?v=' + V, { type: 'module' }); }",
     "function makeClWorker() {\n"
     "  const blob = new Blob([__CL_WORKER_SRC], { type: 'application/javascript' });\n"
     "  return new Worker(URL.createObjectURL(blob)); // classic Blob worker — file://-safe\n"
     "}"),
    ("function clInitPayload(elf) { return { elf }; } // module worker fetches its own wasm",
     "function clInitPayload(elf) { return { elf, wasm: __WASM_BYTES }; } // Blob worker can't fetch — hand it the bytes"),
]


def strip_exports(src: str) -> str:
    return re.sub(r"(?m)^export\s+", "", src)


def wrap_module(src: str, exports: list[str]) -> str:
    body = strip_exports(src)
    assigns = "\n".join(f"window.{name} = {name};" for name in exports)
    return f"<script>\n;(function(){{\n{body}\n/* expose */\n{assigns}\n}})();\n</script>\n"


def main() -> int:
    html = (WEB / "index.html").read_text(encoding="utf-8")

    start = html.index('<script type="module">')
    body_start = start + len('<script type="module">')
    close = html.index("</script>", body_start)
    markup = html[:start]
    app_body = html[body_start:close]
    tail = html[close + len("</script>"):]  # "\n</body>\n</html>\n"

    # Inline the classic nacl.min.js (the single file runs from file:// and can't
    # fetch a sibling). vault.js + the storage shim reference the global `nacl`.
    if NACL_TAG not in markup:
        print(f"FAIL: nacl script tag not found in markup (index.html drifted?):\n  {NACL_TAG}", file=sys.stderr)
        return 1
    nacl_src = (WEB / "nacl.min.js").read_text(encoding="utf-8")
    markup = markup.replace(NACL_TAG, f"<script>\n{nacl_src}\n</script>")

    # ── transform the app body ───────────────────────────────────────────
    for old, new in APP_REWRITES:
        if old not in app_body:
            print(f"FAIL: app pattern not found (index.html drifted?):\n  {old}", file=sys.stderr)
            return 1
        app_body = app_body.replace(old, new)

    # embed wasm + ELF after `const V = Date.now();`
    anchor = "const V = Date.now();"
    if anchor not in app_body:
        print("FAIL: app anchor not found", file=sys.stderr)
        return 1
    wasm_b64 = base64.b64encode((PKG / "axiom_sdk_wasm_bg.wasm").read_bytes()).decode("ascii")
    elf_b64 = base64.b64encode((PKG / "axiom-core.elf").read_bytes()).decode("ascii")
    # The CL worker the single file spawns: no-modules glue (defines the global
    # `wasm_bindgen`) + the classic harness, concatenated and base64-inlined. The
    # main thread turns these bytes into a Blob worker (see the makeClWorker
    # rewrite above). `glue` is reused verbatim for the page's own <script>.
    glue = (PKG / "axiom_sdk_wasm.js").read_text(encoding="utf-8")
    harness = (WEB / "cl-worker-nomod.js").read_text(encoding="utf-8")
    worker_b64 = base64.b64encode((glue + "\n" + harness).encode("utf-8")).decode("ascii")
    prelude = (
        anchor
        + "\nconst __b64u8 = s => { const b = atob(s); const u = new Uint8Array(b.length);"
        + " for (let i=0;i<b.length;i++) u[i]=b.charCodeAt(i); return u; };\n"
        + f'const __WASM_BYTES = __b64u8("{wasm_b64}");\n'
        + f'const __ELF_BYTES = __b64u8("{elf_b64}");\n'
        + f'const __CL_WORKER_SRC = __b64u8("{worker_b64}");\n'
    )
    app_body = app_body.replace(anchor, prelude, 1)

    if "import.meta" in app_body or "import(" in app_body:
        print("FAIL: residual ES-module syntax in app body", file=sys.stderr)
        return 1

    # ── assemble: markup + glue + web-module IIFEs + de-moduled app ───────
    # `glue` was read up in the prelude block (reused for the Blob worker too).
    parts = [markup, f"<script>\n{glue}\n</script>\n"]
    for fname, exports in WEB_MODULES:
        parts.append(wrap_module((WEB / fname).read_text(encoding="utf-8"), exports))
    parts.append(
        "<script>\n;(async function(){\n"
        + app_body
        + "\n})().catch(e => { console.error('[axiom] boot failed', e);"
        + " const m=document.getElementById('msg'); if(m){m.textContent='Boot failed: '+(e&&e.message||e);"
        + " m.className='card err'; m.style.display='block';} });\n</script>\n"
    )
    parts.append(tail)

    OUT_DIR.mkdir(exist_ok=True)
    OUT.write_text("".join(parts), encoding="utf-8")
    size_mb = OUT.stat().st_size / (1024 * 1024)
    print(f"built: {OUT}")
    print(f"size:  {size_mb:.1f} MB  (single double-clickable file, no server)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
