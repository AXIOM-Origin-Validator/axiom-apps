// cl-worker-nomod.js — the single-file (Blob) twin of cl-worker.js.
//
// cl-worker.js is an ES-MODULE worker: it `import`s the web-target glue and
// fetches its own wasm + ELF. Neither works in the single-file build — a
// file:// page has nothing to fetch and module Blob workers are unreliable
// there. So pack.py builds a CLASSIC worker instead: it PREPENDS the
// no-modules wasm-bindgen glue (which defines the global `wasm_bindgen`, with
// .setup/.cl1Run/.cl5Run attached) to this harness, base64-inlines the pair,
// and the main thread spawns it from a Blob URL. The wasm + ELF bytes can't be
// fetched here, so they arrive in the `init` message.
//
// This file is NEVER shipped on its own — it only exists to be concatenated by
// pack.py. The HTTP build keeps using cl-worker.js unchanged.

let ready = null;

self.onmessage = async (e) => {
  const m = e.data || {};
  try {
    if (m.type === 'init') {
      // `wasm_bindgen(bytes)` instantiates THIS worker's own wasm instance from
      // the bytes the main thread copied in; setup() loads the same ELF bytes
      // (same image = same CoreID as the main thread).
      ready = (async () => {
        await wasm_bindgen({ module_or_path: m.wasm });
        wasm_bindgen.setup(m.elf);
      })();
      await ready;
      self.postMessage({ id: m.id, ok: true });
      return;
    }
    if (ready) await ready; else throw new Error('cl-worker: not initialized');

    let proof;
    if (m.type === 'cl1') {
      // cl1Run's 7 args in order; factCertificates (CBOR Vec<VBCProofBundle>,
      // YP §26.17.6.5 B4) is the input the in-process run gets too.
      proof = wasm_bindgen.cl1Run(m.txJson, m.stateJson, m.prevReceipts || undefined, m.factChain || undefined, m.privateKey, m.now,
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
      proof = wasm_bindgen.cl5Run(m.receiverPk, m.chequeBundle, BigInt(m.balance), BigInt(m.walletSeq),
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
