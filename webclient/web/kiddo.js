// KIDDO for web — DEV-ONLY mail transport, mirroring the native AxiomKiddo
// (apps/macos/AxiomKiddo). A browser dev wallet cannot speak POP3/SMTP/raw
// TCP, so it drives those line protocols over TOT's dev-gated /fatmama/<n>
// WS↔TCP tunnel (browser ↔ TOT ↔ FATMAMA; FATMAMA has no webhook). Two jobs,
// same as AccountWorker:
//   1. XAXIOM-REGISTER the wallet email (so FATMAMA spools its inbound mail)
//   2. POP3-drain the mailbox into the wallet's storage maildir/inbox/new
//
// Send is the other direction (outbox → TOT /intake, no auth) and lives in
// transport.js. This file is the RECEIVE half and is dev-only — production
// receive is the validator's ANTIE delivering to the user's real email.
//
// Tunnel index convention (tot config [[fatmama]]): 0 = SMTP (register),
// 1 = POP3 (pull). NO AUTH on the dev path: POP3 password defaults to "x",
// SMTP skips AUTH — matches Pop3Client / FatmamaRegister / SmtpClient.
//
// NOTE: browser-verification pending (no JS runtime on the build host); this
// is a faithful port of the Swift reference, to validate in a browser against
// a running dev env + TOT built with --features dev-fatmama.

const CRLF = '\r\n';
const enc = s => new TextEncoder().encode(s);
const asAscii = u8 => { let s = ''; for (let i = 0; i < u8.length; i++) s += String.fromCharCode(u8[i]); return s; };
function concat(a, b) { const o = new Uint8Array(a.length + b.length); o.set(a, 0); o.set(b, a.length); return o; }
function indexOfSeq(buf, seq, from = 0) {
  outer: for (let i = from; i + seq.length <= buf.length; i++) {
    for (let j = 0; j < seq.length; j++) if (buf[i + j] !== seq[j]) continue outer;
    return i;
  }
  return -1;
}
const CRLF_B = enc(CRLF);
const DOT_TERM = enc(CRLF + '.' + CRLF); // multiline terminator

// Mixed-content TLS gateway upgrade for the /fatmama receive tunnel — mirror of
// transport.js gwWs. An https-hosted page (GitHub Pages, the only way phone users
// reach the wallet) cannot open insecure ws://, so route through the env's Caddy
// front proxy: ws://HOST:PORT/REST -> wss://HOST/tot/PORT/REST. Without this the
// SEND path (intake/nabla) upgraded but the RECEIVE poll (/fatmama) stayed raw
// ws:// and was browser-blocked → genesis "hop 0 timed out after N poll rounds".
// On file:// / http://localhost the URL is returned unchanged.
const TLS_GATEWAY = (typeof location !== 'undefined' && location.protocol === 'https:');
function gwWs(wsUrl) {
  if (!TLS_GATEWAY || !wsUrl) return wsUrl;
  try {
    const u = new URL(wsUrl);
    if (u.protocol !== 'ws:') return wsUrl;            // already wss:// — leave it
    return `wss://${u.hostname}/tot/${u.port || '80'}${u.pathname}${u.search}`;
  } catch (_) { return wsUrl; }
}

// A byte-stream session over the /fatmama tunnel WebSocket. Buffers inbound
// bytes; exposes readLine (CRLF), readMultiline (… CRLF.CRLF), and send.
function openSession(wsUrl, { connectTimeoutMs = 8000, ioTimeoutMs = 30000 } = {}) {
  return new Promise((resolve, reject) => {
    let ws;
    try { ws = new WebSocket(gwWs(wsUrl)); } catch (e) { reject(e); return; }
    ws.binaryType = 'arraybuffer';
    let buf = new Uint8Array(0);
    let waiter = null; // { need: (buf)=>idx|-1, resolve, reject, timer }
    const pump = () => {
      if (!waiter) return;
      const idx = waiter.need(buf);
      if (idx >= 0) {
        const out = buf.slice(0, idx);
        buf = buf.slice(idx);
        clearTimeout(waiter.timer);
        const w = waiter; waiter = null;
        w.resolve(out);
      }
    };
    ws.onmessage = ev => { buf = concat(buf, new Uint8Array(ev.data)); pump(); };
    const fail = msg => { if (waiter) { clearTimeout(waiter.timer); waiter.reject(new Error(msg)); waiter = null; } };
    ws.onerror = () => fail('fatmama tunnel ws error');
    ws.onclose = () => fail('fatmama tunnel closed');
    const ct = setTimeout(() => { try { ws.close(); } catch (_) {} reject(new Error('fatmama tunnel connect timeout')); }, connectTimeoutMs);

    const readUntil = need => new Promise((res, rej) => {
      if (waiter) { rej(new Error('concurrent read')); return; }
      const timer = setTimeout(() => { waiter = null; rej(new Error('fatmama tunnel io timeout')); }, ioTimeoutMs);
      waiter = { need, resolve: res, reject: rej, timer };
      pump();
    });

    ws.onopen = () => {
      clearTimeout(ct);
      resolve({
        // read one CRLF-terminated line (returns text, CRLF stripped)
        async readLine() {
          const bytes = await readUntil(b => { const i = indexOfSeq(b, CRLF_B); return i < 0 ? -1 : i + 2; });
          return asAscii(bytes).replace(/\r\n$/, '');
        },
        // read a dot-terminated multiline body; returns the raw bytes with
        // the trailing CRLF.CRLF removed and dot-unstuffing applied (§3).
        async readMultiline() {
          const bytes = await readUntil(b => { const i = indexOfSeq(b, DOT_TERM); return i < 0 ? -1 : i + DOT_TERM.length; });
          let body = bytes.slice(0, bytes.length - DOT_TERM.length); // drop CRLF.CRLF
          // dot-unstuff: a line starting ".." → ".".
          const out = []; let i = 0;
          while (i < body.length) {
            if (body[i] === 0x2e /* . */ && (i === 0 || (body[i-1] === 0x0a))) { i++; continue; }
            out.push(body[i++]);
          }
          return Uint8Array.from(out);
        },
        send(line) { ws.send(enc(line + CRLF)); },
        close() { try { ws.close(); } catch (_) {} },
      });
    };
  });
}

// ── Carrier email strip — the ONE strip site (Linux ruling 2026-06-09) ──
// SMTP can't ship binary, so FATMAMA wraps the UMP CBOR in an RFC822 email
// with a base64 body. That wrapper is a CARRIER concern: kiddo strips it
// here so the no_std SDK machines only ever see raw CBOR (symmetric with
// outbound, where TOT /intake takes a raw UMP frame). MIME parsing must
// never leak into sdk-core. Mirrors sdk-core/src/recv.rs::unwrap_email_body.

function decodeQuotedPrintable(s) {
  return s
    .replace(/=\r?\n/g, '')
    .replace(/=([0-9A-Fa-f]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16)));
}

// raw: Uint8Array POP3 message (headers + base64-CBOR body, possibly SMTP
// double-wrapped / quoted-printable). Returns Uint8Array of raw CBOR, or
// null if it isn't a well-formed email body.
function stripEmailToCbor(raw) {
  let text = '';
  for (let i = 0; i < raw.length; i++) text += String.fromCharCode(raw[i]);
  const normalized = text.replace(/\r\n/g, '\n');
  const sep = normalized.indexOf('\n\n');
  if (sep < 0) return null;
  const headers = normalized.slice(0, sep);
  let body = normalized.slice(sep + 2).trim();
  if (/quoted-printable/i.test(headers)) body = decodeQuotedPrintable(body);
  // SMTP double-wrap (an inner From:/Subject: AXIOM/ message).
  if (body.startsWith('From:') || body.startsWith('Subject: AXIOM/')) {
    const isep = body.indexOf('\n\n');
    if (isep >= 0) {
      const innerHeaders = body.slice(0, isep);
      body = body.slice(isep + 2).trim();
      if (/quoted-printable/i.test(innerHeaders)) body = decodeQuotedPrintable(body);
    }
  }
  try {
    const bin = atob(body.replace(/\s+/g, ''));
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch (_) {
    return null;
  }
}

const expectOk = line => { if (!line.trimStart().startsWith('+OK')) throw new Error('POP3: ' + line); };

// RFC 1939 drain: USER/PASS/STAT/RETR n/DELE n/QUIT. Mirrors Pop3Client.
export async function pop3FetchAll(wsUrl, mailbox, password = 'x') {
  const s = await openSession(wsUrl);
  try {
    expectOk(await s.readLine());                 // +OK banner
    s.send('USER ' + mailbox); expectOk(await s.readLine());
    s.send('PASS ' + password); expectOk(await s.readLine());
    s.send('STAT');
    const stat = await s.readLine();              // "+OK <count> <octets>"
    const parts = stat.trim().split(/\s+/);
    const count = (parts[0] === '+OK') ? parseInt(parts[1], 10) : NaN;
    if (!Number.isFinite(count)) throw new Error('POP3 STAT: ' + stat);
    const out = [];
    for (let n = 1; n <= count; n++) {
      s.send('RETR ' + n);
      expectOk(await s.readLine());
      out.push(await s.readMultiline());
      s.send('DELE ' + n); expectOk(await s.readLine());
    }
    s.send('QUIT'); await s.readLine().catch(() => {});
    return out;
  } finally { s.close(); }
}

// XAXIOM-REGISTER over the SMTP tunnel. Mirrors FatmamaRegister.register.
export async function fatmamaRegister(wsUrl, email) {
  const s = await openSession(wsUrl, { ioTimeoutMs: 10000 });
  try {
    const greet = await s.readLine();             // 220 banner
    if (greet.charAt(0) !== '2') throw new Error('FATMAMA: ' + greet);
    s.send('EHLO axiomweb');  await readCode(s, 250);
    s.send('XAXIOM-REGISTER ' + email); await readCode(s, 250);
    s.send('QUIT');                               // best-effort
  } finally { s.close(); }
}
async function readCode(s, expected) {
  // SMTP multiline: "250-..." continuations until "250 ..."
  let line;
  do { line = await s.readLine(); } while (line.length >= 4 && line.charAt(3) === '-');
  const code = parseInt(line.slice(0, 3), 10);
  if (code !== expected) throw new Error('FATMAMA ' + code + ': ' + line);
}

// One receive cycle for a dev account: register (idempotent) + drain POP3
// into the wallet's storage maildir/inbox/new. `storage` is the same
// JsStorage-shaped object the SDK uses; `walletDir` is the wallet's dir.
// Returns the number of messages landed. Mirrors AccountWorker.pop3Tick +
// registerFatmama. Call on a timer (e.g. every few seconds) while a send is
// in flight (witness responses arrive this way) and on the Receive screen.
export async function kiddoReceiveCycle({ smtpWs, pop3Ws, email, storage, walletDir }) {
  await fatmamaRegister(smtpWs, email).catch(() => {}); // dev route self-heal
  const msgs = await pop3FetchAll(pop3Ws, email);
  const inboxNew = `${walletDir}/maildir/inbox/new`;
  let landed = 0;
  for (const body of msgs) {
    // Strip the carrier email wrapper → raw CBOR. The SDK machines read raw
    // CBOR only; MIME never reaches no_std core. Malformed → log + skip.
    const cbor = stripEmailToCbor(body);
    if (!cbor) {
      console.warn('[kiddo] skipping inbox message: not a well-formed base64-CBOR email');
      continue;
    }
    // Server-generated unique name (client cannot influence the path);
    // same shape as FATMAMA's deliver_to_maildir / Kiddo's pop3Tick.
    const name = `${(Date.now() / 1000).toFixed(6)}.${landed}.web.${crypto.randomUUID()}`;
    storage.writeAtomic(`${inboxNew}/${name}`, cbor);
    landed++;
  }
  return landed;
}
