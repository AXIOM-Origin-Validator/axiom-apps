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
      // cl1Run's 7 args in order; factCertificates (CBOR Vec<VBCProofBundle>,
      // YP §26.17.6.5 B4) is the input the in-process run gets too.
      proof = cl1Run(m.txJson, m.stateJson, m.prevReceipts || undefined, m.factChain || undefined, m.privateKey, m.now,
                     m.factCertificates || undefined);
    } else if (m.type === 'cl5') {
      // cl5Run's order: (receiverPk, chequeBundle, balance, walletSeq,
      // currentHibernation [YPX-020], currentWallClockLock [§5.2.2c — CL5
      // refuses a redeem while the stake lock is held, KI#133],
      // currentEmissionClaimedEpoch [§4.2a], currentStakeFloorUntil +
      // currentWalletFormat [ValidatorJoin §6b.13 — REQUIRED, no default: a
      // missing value throws and the run falls back in-process], stateId, chequeClaimProof,
      // txidAttestation, privateKey, now, oodsAttestation [YPX-022 §2.2.2]).
      // Every field must be the one the envelope carries or the proof's
      // input_hash mismatches Lambda's recompute. Replies with the WHOLE run
      // (Cl5Run CBOR: proof + the inputs it ran + Core's outputs) — the
      // redeem machine builds its Nabla leg from it (Fork Settlement W7e-a).
      proof = cl5Run(m.receiverPk, m.chequeBundle, BigInt(m.balance), BigInt(m.walletSeq),
                     BigInt(m.currentHibernation || 0n), BigInt(m.currentWallClockLock || 0n),
                     BigInt(m.currentEmissionClaimedEpoch || 0n),
                     BigInt(m.currentStakeFloorUntil), m.currentWalletFormat, m.stateId,
                     m.chequeClaimProof || undefined, m.txidAttestation || undefined, m.privateKey, m.now,
                     m.oodsAttestation || undefined,
                     // F-1(b) (2026-10-01): the receiver's last receipt, CBOR
                     // Vec<Receipt> — REQUIRED (cl5Run throws without it).
                     m.prevReceipts);
    } else {
      throw new Error('cl-worker: unknown message type ' + m.type);
    }
    // Transfer the result buffer (cl1: the proof; cl5: the Cl5Run CBOR) —
    // zero-copy back to the main thread.
    self.postMessage({ id: m.id, ok: true, proof }, [proof.buffer]);
  } catch (err) {
    self.postMessage({ id: m.id, ok: false, error: String((err && err.message) || err) });
  }
};
