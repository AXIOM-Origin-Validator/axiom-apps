// cl-worker.js — runs the heavy CL1/CL5 AVM proof generation OFF the UI
// thread, so signing a transaction doesn't freeze the page.
//
// The worker loads its OWN wasm instance + the canonical Core ELF (passed in
// the `init` message), then answers `cl1`/`cl5` requests by reference id. The
// main thread's transport calls these via postMessage; the SDK's async driver
// awaits the result, falling back to in-process signing if no worker is wired.
//
// ES-module worker — used by the HTTP build. The single-file (file://) build
// can't load a sibling worker, so it falls back to in-process automatically.

import init, { setup, cl1Run, cl5Run } from '../pkg/axiom_sdk_wasm.js';

let ready = null;

self.onmessage = async (e) => {
  const m = e.data || {};
  try {
    if (m.type === 'init') {
      // init() fetches ../pkg/axiom_sdk_wasm_bg.wasm relative to the glue;
      // setup() loads the ELF this worker will run (same bytes = same CoreID).
      ready = (async () => { await init(); setup(m.elf); })();
      await ready;
      self.postMessage({ id: m.id, ok: true });
      return;
    }
    if (ready) await ready; else throw new Error('cl-worker: not initialized');

    let proof;
    if (m.type === 'cl1') {
      proof = cl1Run(m.txJson, m.stateJson, m.prevReceipts || undefined, m.factChain || undefined, m.privateKey, m.now);
    } else if (m.type === 'cl5') {
      // YPX-020: current_hibernation is cl5Run's slot 5 (after walletSeq).
      // YPX-022 §2.2.2: oodsAttestation trails — a hibernation-exit
      // (HAL/RECALL completion) redeem's CL5 must include the reading or
      // the proof's input_hash mismatches the envelope Lambda recomputes.
      proof = cl5Run(m.receiverPk, m.chequeBundle, BigInt(m.balance), BigInt(m.walletSeq),
                     BigInt(m.currentHibernation || 0), m.stateId,
                     m.chequeClaimProof || undefined, m.txidAttestation || undefined, m.privateKey, m.now,
                     m.oodsAttestation || undefined);
    } else {
      throw new Error('cl-worker: unknown message type ' + m.type);
    }
    // Transfer the proof buffer (zero-copy back to the main thread).
    self.postMessage({ id: m.id, ok: true, proof }, [proof.buffer]);
  } catch (err) {
    self.postMessage({ id: m.id, ok: false, error: String((err && err.message) || err) });
  }
};
