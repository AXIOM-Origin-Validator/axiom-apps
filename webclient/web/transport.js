// AXIOM browser transport — the one capability the WASM SDK reaches the
// network through, and it ONLY ever talks to TOT (docs/AXIOM_DESIGN_TOT.md,
// docs/AXIOM_DESIGN_WasmClient.md §3). No raw TCP, no SMTP.
//
// Shape consumed by axiom-sdk-wasm's JsAsyncTransport:
//   async httpRequest(address, method, path, body) -> Uint8Array
//   async nablaTcp(address, payload)               -> Uint8Array
//   async deliver(validatorEmail, payload)         -> void
//
// `makeTotTransport(config)` builds it from a resolver config:
//   {
//     // map a validator's delivery email -> its TOT /intake ws:// URL
//     intakeWsFor(validatorEmail) -> "ws://host:port/intake",
//     // map a Nabla TCP "host:port" -> a TOT /nabla/<n> ws:// tunnel URL
//     nablaWsFor(nablaAddress)     -> "ws://host:port/nabla/0",
//     // optional: map a Nabla "host:port" -> "http://host:port" for the
//     // few HTTP-only dashboard reads (not used on the protocol path)
//     httpBaseFor(nablaAddress)    -> "http://host:port",
//   }

const CONNECT_TIMEOUT_MS = 8000;
const RESPONSE_TIMEOUT_MS = 30000;

// Wrap a raw UMP-envelope payload in the RFC822 email ANTIE expects:
//   From: <wallet>  To: <validator>  Subject: AXIOM/<type>/<request_id>
//   <blank line>  <base64(UMP envelope), wrapped at 76 cols>
// ANTIE drops anything without this Subject ("Invalid subject format").
// The carrier owns this wrapper (AXIOM_DESIGN_WasmClient.md §4.3); the
// SDK produced the raw UMP CBOR. The From routes ANTIE's response back to
// the wallet's FATMAMA mailbox; the type routes the request (witness/redeem).
function b64(u8) { let s = ''; for (let i = 0; i < u8.length; i++) s += String.fromCharCode(u8[i]); return btoa(s); }
function buildEmail(from, to, msgType, payload) {
  const body = b64(payload).replace(/(.{76})/g, '$1\r\n');
  const reqId = (typeof crypto !== 'undefined' && crypto.randomUUID) ? crypto.randomUUID() : String(Date.now());
  const headers =
    `From: ${from}\r\nTo: ${to}\r\nSubject: AXIOM/${msgType}/${reqId}\r\n` +
    `Message-ID: <${reqId}@web>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n`;
  return new TextEncoder().encode(headers + body + '\r\n');
}

function beU32(n) {
  const b = new Uint8Array(4);
  b[0] = (n >>> 24) & 0xff; b[1] = (n >>> 16) & 0xff;
  b[2] = (n >>> 8) & 0xff;  b[3] = n & 0xff;
  return b;
}
function readBeU32(buf, off) {
  return ((buf[off] << 24) | (buf[off+1] << 16) | (buf[off+2] << 8) | buf[off+3]) >>> 0;
}
function concat(a, b) {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0); out.set(b, a.length);
  return out;
}


// Open a ws://, send the binary `frame`, and resolve once a full
// [4-byte BE length][body] response has been reassembled (the Nabla TCP
// wire, relayed verbatim through TOT's /nabla tunnel). `expectResponse`
// = false for /intake (fire-and-forget, no reply).
function wsRoundtrip(url, frame, expectResponse) {
  return new Promise((resolve, reject) => {
    let ws;
    try { ws = new WebSocket(url); } catch (e) { reject(e); return; }
    ws.binaryType = 'arraybuffer';
    let acc = new Uint8Array(0);
    let settled = false;
    const done = (fn, v) => { if (settled) return; settled = true; clearTimeout(ct); clearTimeout(rt); try { ws.close(); } catch (_) {} fn(v); };
    const ct = setTimeout(() => done(reject, new Error(`TOT connect timeout: ${url}`)), CONNECT_TIMEOUT_MS);
    let rt;
    ws.onopen = () => {
      clearTimeout(ct);
      ws.send(frame);
      if (!expectResponse) { done(resolve, new Uint8Array(0)); return; }
      rt = setTimeout(() => done(reject, new Error(`TOT response timeout: ${url}`)), RESPONSE_TIMEOUT_MS);
    };
    ws.onmessage = (ev) => {
      if (!expectResponse) return;
      acc = concat(acc, new Uint8Array(ev.data));
      if (acc.length >= 4) {
        const len = readBeU32(acc, 0);
        if (acc.length >= 4 + len) done(resolve, acc.slice(4, 4 + len));
      }
    };
    ws.onerror = () => done(reject, new Error(`TOT ws error: ${url}`));
    ws.onclose = () => { if (expectResponse) done(reject, new Error(`TOT ws closed before full response: ${url}`)); };
  });
}

export function makeTotTransport(config) {
  const need = (fn, name) => { if (typeof config[fn] !== 'function') throw new Error(`makeTotTransport: config.${fn} (${name}) required`); };
  need('intakeWsFor', 'email -> /intake ws url');
  need('nablaWsFor', 'nabla addr -> /nabla ws url');

  const t = {
    // Nabla CBOR-over-TCP, tunnelled through TOT /nabla/<n>. The SDK hands
    // a bare CBOR WireMessage; we add the [4-byte BE length] frame the
    // Nabla TCP server expects (matches sdk/client/src/tcp_nabla.rs send_recv).
    async nablaTcp(address, payload) {
      const url = config.nablaWsFor(address);
      if (!url) throw new Error(`no TOT /nabla tunnel for ${address}`);
      const frame = concat(beU32(payload.length), payload);
      return await wsRoundtrip(url, frame, true);
    },

    // One outbound UMP envelope -> TOT /intake. TOT writes the WS frame
    // verbatim to the validator's maildir, where ANTIE reads it as an email
    // — so we wrap the raw UMP payload in the RFC822 envelope ANTIE expects.
    async deliver(validatorEmail, payload) {
      const url = config.intakeWsFor(validatorEmail);
      if (!url) throw new Error(`no TOT /intake for ${validatorEmail}`);
      const email = buildEmail(
        config.fromEmail || 'wallet@axiom.internal',
        validatorEmail,
        config.messageType || 'witness',
        payload,
      );
      await wsRoundtrip(url, email, false);
    },

    // HTTP — only for non-protocol dashboard reads. The protocol Nabla
    // path is nablaTcp (TCP via the tunnel). Kept for completeness.
    async httpRequest(address, method, path, body) {
      if (typeof config.httpBaseFor !== 'function') throw new Error('httpRequest: config.httpBaseFor not configured');
      const base = config.httpBaseFor(address);
      if (!base) throw new Error(`no http base for ${address}`);
      const init = { method };
      if (body && body.length) init.body = body;
      const resp = await fetch(base + path, init);
      const buf = await resp.arrayBuffer();
      return new Uint8Array(buf);
    },
  };
  // CL1/CL5 worker offload — only present when a worker is wired (HTTP build).
  // Absent → the SDK driver runs signing in-process (single-file / no worker).
  if (typeof config.cl1 === 'function') t.cl1 = config.cl1;
  if (typeof config.cl5 === 'function') t.cl5 = config.cl5;
  return t;
}

// Build a transport config from a discovery snapshot: a list of TOT
// validators (each with a delivery email + a TOT ws base) and the ordered
// attested Nabla set served by the tunnel. Endpoints come from the `tot:`
// carriers in validators.list / VSP discovery — see
// CachedHint::tot_endpoint in sdk-core.
//
//   validators: [{ email, totWs }]   totWs = "ws://host:port"
//   nablas:     ["host:port", ...]    (the attested order; index = /nabla/<i>)
//   nablaTotWs: "ws://host:port"      the TOT that tunnels to those nablas
// Mixed-content TLS gateway upgrade.
//
// Browsers forbid an HTTPS page (e.g. the hosted webclient on GitHub Pages,
// the only way phone users reach it) from opening insecure ws:// / http://
// to the env — so every connection is blocked with "TOT ws error … hop 0".
// When (and ONLY when) we're served over https, route through the env's TLS
// gateway (Caddy on <host>:443) which terminates TLS and path-proxies back to
// the plaintext TOT / Nabla ports:
//   ws://HOST:PORT/REST   -> wss://HOST/tot/PORT/REST   (protocol path)
//   http://HOST:PORT/REST -> https://HOST/nh/PORT/REST  (dashboard reads only)
// On file:// or http://localhost the originals are returned unchanged, so the
// single-file build and local hosting keep working against a plaintext env.
const TLS_GATEWAY = (typeof location !== 'undefined' && location.protocol === 'https:');

function gwWs(wsUrl) {
  if (!TLS_GATEWAY || !wsUrl) return wsUrl;
  try {
    const u = new URL(wsUrl);
    if (u.protocol !== 'ws:') return wsUrl;            // already wss:// — leave it
    return `wss://${u.hostname}/tot/${u.port || '80'}${u.pathname}${u.search}`;
  } catch (_) { return wsUrl; }
}

function gwHttpBase(addr) {
  if (!TLS_GATEWAY) return `http://${addr}`;
  const [host, port] = addr.split(':');
  return `https://${host}/nh/${port || '80'}`;
}

export function totConfigFrom({ validators, nablas, nablaTotWs, fromEmail, messageType, cl1, cl5 }) {
  const intake = new Map(validators.map(v => [v.email, `${v.totWs}/intake`]));
  const nablaIdx = new Map((nablas || []).map((addr, i) => [addr, i]));
  return {
    intakeWsFor: (email) => gwWs(intake.get(email)),
    nablaWsFor: (addr) => {
      const i = nablaIdx.get(addr);
      return i === undefined ? undefined : gwWs(`${nablaTotWs}/nabla/${i}`);
    },
    httpBaseFor: (addr) => gwHttpBase(addr),
    // Carrier email-wrap context (deliver → ANTIE).
    fromEmail,                          // routes ANTIE's response back
    messageType: messageType || 'witness', // ANTIE dispatch (witness/redeem)
    // CL1/CL5 worker offload (optional — passed through to makeTotTransport).
    cl1, cl5,
  };
}
