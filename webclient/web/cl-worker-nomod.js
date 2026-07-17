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
      proof = wasm_bindgen.cl1Run(m.txJson, m.stateJson, m.prevReceipts || undefined, m.factChain || undefined, m.privateKey, m.now);
    } else if (m.type === 'cl5') {
      // YPX-020: current_hibernation is cl5Run's slot 5 (after walletSeq).
      // YPX-022 §2.2.2: oodsAttestation trails — a hibernation-exit
      // (HAL/RECALL completion) redeem's CL5 must include the reading or
      // the proof's input_hash mismatches the envelope Lambda recomputes.
      proof = wasm_bindgen.cl5Run(m.receiverPk, m.chequeBundle, BigInt(m.balance), BigInt(m.walletSeq),
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
