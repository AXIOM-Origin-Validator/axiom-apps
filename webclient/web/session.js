// AXIOM browser reply leg — TOT `/session` for NORMAL (real-email) wallets.
//
// WHY THIS EXISTS. The SDK machines never "receive" over the network: they poll
// `<walletDir>/maildir/inbox/new` and read raw CBOR. Something has to fill that
// inbox. For DEV (`@axiom.internal`) wallets that is `kiddo.js`, draining
// FATMAMA over the `/fatmama/*` tunnels. **That tunnel is `#[cfg(feature =
// "dev-fatmama")]` and is COMPILED OUT of production TOT** (verified 2026-09-07:
// zeta's tot has 0 fatmama symbols, the local dev build has 5). So a dev wallet
// cannot complete a round against a real validator, and until now the webclient
// created nothing else.
//
// The reply path for normal wallets was already finished on the validator side
// and simply had no browser client:
//
//   client --(binary UMP frame)--> TOT /session
//        TOT stamps `X-TOT-Session: <id>` and delivers to its validator maildir
//        ANTIE sees the stamp, and instead of MAILING the reply deposits it in
//          <custody_outbox>/<session id>/            (suppress_email = true)
//        TOT polls that directory and pumps each reply back down THE SAME SOCKET
//   client <--(binary reply frame)-- TOT /session
//
// AXIOM_DESIGN_TOT.md §5.4, YPX-023 §3.3. So this file is small on purpose: it
// holds the socket, and lands what arrives into the inbox the machines already
// read. It decodes no protocol bytes.
//
// ⚠ ONE SESSION PER VALIDATOR, HELD. TOT mints the session id per WEBSOCKET and
// watches only that session's directory, so replies come back on the connection
// that sent the request. A k=3 round talks to three validators, so it holds
// three sockets. Closing one early loses that validator's reply — TOT deletes
// the session directory on drop.
//
// ⚠ NEVER USE THIS FOR A DEV WALLET. The route IS the client's declaration that
// it is a normal wallet; ANTIE cross-checks it against the sender address and
// REJECTS a disagreement ("stamp and address disagree", YPX-023 §2B.4). Dev
// traffic is FATMAMA-to-FATMAMA and gets its own stamp later. `index.html`
// picks the leg from `is_dev_wallet`-equivalent class, never from a preference.

import { stripEmailToCbor } from './kiddo.js';

const CONNECT_TIMEOUT_MS = 8000;

// Server-shaped unique maildir name — the client must not influence the path.
// Same shape kiddo.js uses so the two legs are indistinguishable downstream.
function inboxName(n) {
  const uuid = (typeof crypto !== 'undefined' && crypto.randomUUID)
    ? crypto.randomUUID() : String(Math.random()).slice(2);
  return `${(Date.now() / 1000).toFixed(6)}.${n}.web.${uuid}`;
}

/// Hold TOT `/session` sockets and land replies into the wallet's inbox.
///
/// `storage` is the JsStorage-shaped object the SDK uses; `walletDir` the
/// wallet's directory. `onLanded(count, validatorEmail)` is optional telemetry.
export function makeSessionPool({ storage, walletDir, onLanded }) {
  const inboxNew = `${walletDir}/maildir/inbox/new`;
  const socks = new Map();   // validatorEmail -> { ws, ready }
  let landed = 0;
  let closed = false;

  function land(bytes, validatorEmail) {
    // The reply is carrier-wrapped exactly as the mail leg's would be; strip to
    // raw CBOR, because MIME never reaches no_std machine code.
    const cbor = stripEmailToCbor(bytes);
    if (!cbor) {
      console.warn('[session] dropping reply: not a well-formed base64-CBOR email');
      return;
    }
    storage.writeAtomic(`${inboxNew}/${inboxName(landed)}`, cbor);
    landed++;
    if (onLanded) { try { onLanded(landed, validatorEmail); } catch (_) {} }
  }

  function open(validatorEmail, wsUrl) {
    const entry = { ws: null, ready: null };
    entry.ready = new Promise((resolve, reject) => {
      let settled = false;
      const done = (fn, arg) => { if (!settled) { settled = true; fn(arg); } };
      let ws;
      try { ws = new WebSocket(wsUrl); } catch (e) { done(reject, e); return; }
      ws.binaryType = 'arraybuffer';
      entry.ws = ws;
      const ct = setTimeout(
        () => done(reject, new Error(`TOT /session connect timeout: ${wsUrl}`)),
        CONNECT_TIMEOUT_MS);
      ws.onopen = () => { clearTimeout(ct); done(resolve, ws); };
      ws.onmessage = (ev) => {
        const d = ev.data;
        if (d instanceof ArrayBuffer) land(new Uint8Array(d), validatorEmail);
        // Text frames are not part of the protocol path — TOT sends binary.
      };
      ws.onerror = () => { clearTimeout(ct); done(reject, new Error(`TOT /session ws error: ${wsUrl}`)); };
      ws.onclose = () => {
        clearTimeout(ct);
        socks.delete(validatorEmail);
        // ⚠ NOT auto-reconnected. A new socket is a NEW session id and a NEW
        // directory on the validator; replies already deposited for the old id
        // are deleted when TOT drops it. Reconnecting silently would look like
        // recovery while losing the round's replies. The round fails loudly
        // instead, and the wallet retries — which is the honest behaviour.
        if (!closed) console.warn(`[session] closed for ${validatorEmail} — replies for this session are gone`);
        done(reject, new Error(`TOT /session closed: ${wsUrl}`));
      };
    });
    socks.set(validatorEmail, entry);
    return entry;
  }

  return {
    /// Send one carrier-wrapped envelope over this validator's held session.
    /// The reply arrives asynchronously on the same socket and is landed in the
    /// inbox; the machines pick it up on their next poll, exactly as with mail.
    async deliver(validatorEmail, wsUrl, emailBytes) {
      let entry = socks.get(validatorEmail);
      if (!entry) entry = open(validatorEmail, wsUrl);
      const ws = await entry.ready;
      if (ws.readyState !== WebSocket.OPEN) {
        throw new Error(`TOT /session not open for ${validatorEmail}`);
      }
      ws.send(emailBytes);
    },

    landedCount() { return landed; },

    /// Close every held session. Call when the wallet locks or the round set is
    /// finished — TOT removes the session directory on disconnect.
    closeAll() {
      closed = true;
      for (const [, e] of socks) { try { e.ws && e.ws.close(); } catch (_) {} }
      socks.clear();
    },
  };
}
