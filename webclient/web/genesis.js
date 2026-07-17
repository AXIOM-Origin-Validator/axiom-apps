// genesis.js — unified "claim dev funds" flow over the WASM SDK.
//
// The Rust binding splits the claim into two calls because a browser
// Promise cannot hold the wallet's `&mut self` borrow across an await:
//
//   wallet.claimGenesisFund(transport, params) -> Promise<outcome>   (network)
//   wallet.commitGenesisFund(stateId, receipt, factChain)            (local, sync)
//
// `claimGenesis()` chains them so callers (the "Claim dev funds" button)
// see one async call. Every outbound payload is a typed-UMP WitnessRequest
// built in sdk-core (no hand-rolled CBOR); this file only sequences the
// two phases and converts the hex hand-off.
//
// params: {
//   amount,          // BigInt — atoms to claim
//   reference,       // string — e.g. "sdk"
//   offeredFee,      // BigInt — atoms (>= MIN_OFFERED_FEE)
//   validators,      // [{ validatorId: hex64, email }]   (TOT-supported only)
//   k,               // number — witnesses required (3 for genesis)
//   inboxNew,        // "maildir/inbox/new"
//   inboxCur,        // "maildir/inbox/cur"
//   pollIntervalMs,  // number — inbox poll backoff
//   pollMaxRounds,   // number — per-hop poll budget before timeout
//   nablaTcpAddresses, // string[] — Nabla "host:port" (via TOT /nabla/<n>)
//                      //   for the post-round register; [] skips register
// }


// YPX-021 §8.2: cache the writer's OODS reading a fund outcome carried
// (RegisterAck → machine → outcome.oodsAttestationCbor). The next op sends it
// to Core; recoveries (heal / HAL / reclaim) REQUIRE a healthy reading — a
// wallet that never stashed one has every recovery rejected OodsUnhealthyRetry.
function stashOods(wallet, o) {
  try {
    if (o && o.oodsAttestationCbor && o.oodsAttestationCbor.length) {
      wallet.stashOodsAttestation(o.oodsAttestationCbor);
    }
  } catch (_) { /* cache only — never fail the committed op */ }
}

export async function claimGenesis(wallet, transport, params, onStep) {
  // Phase 1 — network: build the GenesisClaim TX, run CL1 locally, drive
  // the serial k-witness round over TOT. Does not touch wallet state.
  const outcome = await wallet.claimGenesisFund(transport, params, onStep || null);
  stashOods(wallet, outcome);

  // Phase 2 — local: advance wallet state atomically (produced_state_id,
  // balance 0, wallet_seq 1, receipt + FACT chain) and persist.
  wallet.commitGenesisFund(
    hexToBytes(outcome.producedStateIdHex),
    outcome.receiptCbor,
    outcome.factChainCbor,
  );

  // Nabla register now runs INSIDE claimGenesisFund (after the witness
  // round) — outcome.registered reflects whether the txid landed in the
  // SMT. Pass params.nablaTcpAddresses to enable it.
  //
  // Phase 3 (still to wire): redeem the genesis cheque bundle to credit the
  // balance — the same path a normal receive uses (wallet.recv + redeem).
  return {
    txid: outcome.txidHex,
    producedStateId: outcome.producedStateIdHex,
    witnessCount: outcome.witnessCount,
    registered: outcome.registered,
    redeemed: false,
    balance: wallet.balance, // still 0 until redeem credits it
  };
}

// Redeem a stored cheque bundle: redeemFund (async/network) → commitRedeem
// (sync/local credit). Same fund→commit split rationale as claimGenesis.
// `redeemParams`: { validators, k, nablaTcpAddresses, inboxNew, inboxCur,
// pollIntervalMs, pollMaxRounds }. Returns the credited balance.
export async function redeem(wallet, transport, chequeId, redeemParams, onStep) {
  const before = wallet.balance; // BigInt — to compute the credited delta
  const outcome = await wallet.redeemFund(transport, chequeId, redeemParams, onStep || null);
  stashOods(wallet, outcome);
  wallet.commitRedeem(
    hexToBytes(outcome.producedStateIdHex),
    outcome.newBalance,      // BigInt
    outcome.newWalletSeq,    // BigInt
    outcome.receiptCbor,
    outcome.factChainCbor,
    chequeId,
  );
  // Record the credit (covers both a genesis self-redeem and a normal
  // receive — one entry, no double-count with the fund phase).
  recordHistory(wallet, String(chequeId).split(':')[0], 'Redeem',
    outcome.newBalance - before, '', 'redeem', outcome.feeBreakdown || []);
  return {
    producedStateId: outcome.producedStateIdHex,
    newBalance: outcome.newBalance,
    registered: outcome.registered,
    balance: wallet.balance, // now credited
  };
}

// Full genesis dev-funds claim: claimGenesis (fund+register+commit) → poll
// the inbox until the self-send cheque arrives (caller runs kiddoReceiveCycle
// + wallet.recv on a timer) → redeem. This helper does the redeem tail once
// a ready bundle exists; the recv polling is the caller's loop.
export async function claimAndRedeem(wallet, transport, claimParams, redeemParams, chequeId) {
  await claimGenesis(wallet, transport, claimParams);
  return await redeem(wallet, transport, chequeId, redeemParams);
}

// Normal send: sendFund (async/network — build TX → CL1 → k-witness round
// over TOT → register) → commitSend (sync/local debit). `amountAtoms` is a
// BigInt; `params` = { validators, k, nablaTcpAddresses, inboxNew, inboxCur,
// pollIntervalMs, pollMaxRounds }. Returns the new (debited) balance.
export async function send(wallet, transport, to, amountAtoms, reference, params, onStep) {
  return await sendInner(wallet, transport, to, amountAtoms, reference, params, onStep);
}

// YPX-001 §1.5.1 — RE-INITIATE a send the scar-consent gate PAUSED, once the
// receiver has shared their 6-digit passcode. The paused send is persisted by
// the SendMachine; the recipient / amount / reference / nonce / epoch are taken
// from that record INSIDE the SDK (not from here), so the rebuilt tx reproduces
// the SAME txid and the validator can match the passcode it stored. Nothing was
// witnessed while paused, so this is the first and only time funds move.
export async function sendWithScarPasscode(wallet, transport, params, passcode, onStep) {
  const rec = wallet.pendingScarSend();
  if (!rec) throw new Error('No paused payment awaiting consent.');
  if (!rec.current) {
    throw new Error(
      'This wallet has moved since the payment was paused, so the paused payment can no longer ' +
      'be completed. Start a fresh send — it will pause again and the receiver will get a new passcode.'
    );
  }
  const p = Object.assign({}, params, { scarPasscode: passcode >>> 0 });
  return await sendInner(wallet, transport, rec.to, BigInt(rec.amount), rec.reference, p, onStep);
}

// The ONE send tail — fund → stash → commit → history. `send()` and
// `sendWithScarPasscode()` differ only in the params they hand the SDK, never
// in what they do with the outcome (no forked commit logic).
async function sendInner(wallet, transport, to, amountAtoms, reference, params, onStep) {
  const o = await wallet.sendFund(transport, to, amountAtoms, reference, params, onStep || null);
  // YPX-021 §8.2: stash the writer's OODS reading this round surfaced so the
  // NEXT op (incl. a recovery, which REQUIRES it under Core's §8.5 gate)
  // carries it — mirror of native nabla.rs caching it from every RegisterAck.
  stashOods(wallet, o);
  // YPX-022 (repurposed): stash the COMPLETED send's tx — the recall target.
  // Only a completed send is recallable (a sub-quorum send is a no-op under
  // the quorum gate), so there is nothing to stash on failure.
  try { if (o.sendTxCbor) wallet.stashLastSendTx(o.sendTxCbor); } catch (_) {}
  wallet.commitSend(
    hexToBytes(o.producedStateIdHex),
    o.newBalance,    // BigInt
    o.newWalletSeq,  // BigInt
    o.receiptCbor,
    o.factChainCbor,
  );
  recordHistory(wallet, o.txidHex, 'Send', amountAtoms, to, reference);
  return {
    txid: o.txidHex,
    newBalance: o.newBalance,
    registered: o.registered,
    balance: wallet.balance, // now debited
  };
}

// Resumable rounds (2026-07-08) — RESUME an interrupted send. Witnessing has
// no protocol expiry, so a per-hop timeout only means the browser stopped
// waiting; the SendMachine persisted the round and this re-enters the SAME
// pipeline: sweep the inbox for responses that arrived after the timeout, then
// continue the remaining hops with the SAME tx (same txid — the content-keyed
// YPX-016 witness cache replays a committed validator's response). Same
// fund→commit shape as send(); on completion the balance is debited. `params`
// is the same shape send() takes — the recipient/amount come from the round.
export async function resumeSend(wallet, transport, params, onStep) {
  // Read the round descriptor BEFORE resuming — the round is discarded on
  // completion, and we want its to/amount for the History row.
  let desc = null;
  try { desc = wallet.resumableSend(); } catch (_) {}
  const o = await wallet.resumeSend(transport, params, onStep || null);
  stashOods(wallet, o);
  try { if (o.sendTxCbor) wallet.stashLastSendTx(o.sendTxCbor); } catch (_) {}
  wallet.commitSend(
    hexToBytes(o.producedStateIdHex),
    o.newBalance,    // BigInt
    o.newWalletSeq,  // BigInt
    o.receiptCbor,
    o.factChainCbor,
  );
  recordHistory(wallet, o.txidHex, 'Send',
    desc ? desc.amount : 0n, desc ? desc.to : '', 'resume');
  return {
    txid: o.txidHex,
    newBalance: o.newBalance,
    registered: o.registered,
    balance: wallet.balance, // now debited
  };
}

// Heal / scar-burn: healFund (async/network — TX_HEAL re-anchor or scar
// burn, auto-selected from wallet state) → commitHeal (sync, clears CLARA
// state for TX_HEAL). `params` = same shape as send/redeem. Returns the
// new balance + whether CLARA state was cleared.
export async function heal(wallet, transport, params, onStep) {
  return await healLike(wallet, 'healFund', 'Heal', 'heal', transport, params, onStep);
}

// Explicit scar-burn — burns ONE scarred FACT link (value DESTROYED). The
// de-orchestrated counterpart heal NO LONGER does implicitly (see
// AXIOM_DESIGN_SelfTransactions.md). burnScarsFund → commitHeal
// (clearClara=false). Re-call while scars remain. User-confirmed in the UI.
export async function burnScars(wallet, transport, params, onStep) {
  return await healLike(wallet, 'burnScarsFund', 'Burn', 'scar_burn', transport, params, onStep);
}

// YPX-020 HAL — RE-ANCHOR a healthy wallet whose prior witnesses are
// unreachable (dead-overlap). halReanchorFund → commitHeal (which stamps the
// hibernation lock the produced state carries). Records a HalReanchor history
// row. After this the wallet is HIBERNATING (send/redeem rejected) until
// halComplete clears it.
export async function halReanchor(wallet, transport, params, onStep) {
  return await healLike(wallet, 'halReanchorFund', 'HalReanchor', 'hal-reanchor', transport, params, onStep);
}

// YPX-020 §2 HAL — COMPLETE recovery by REDEEMING the re-anchor's distress
// (dust self-) cheque. There is no halCompleteFund / separate completion
// self-send anymore: the redeem IS the completion. Core's CL5 zeroes
// hibernation_until in the witnessed receipt; commitRedeem doesn't touch the
// local flag, so we mirror the clear via wallet.clearHibernation(). The distress
// cheque lands in the inbox via the receive pump the caller runs — poll recv
// until it's ready, then redeem it (records ONE dust Redeem row, not a
// "HAL complete" row).
export async function halComplete(wallet, transport, params, onStep) {
  const maildir = (params.inboxNew || '').replace(/\/inbox\/new$/, '');
  const ownAddr = wallet.info().address;
  let chequeId = null;
  const rounds = params.pollMaxRounds || 720;
  for (let i = 0; i < rounds && !chequeId; i++) {
    if (onStep) onStep('recv');
    const cheques = wallet.recv(maildir) || [];
    // The distress cheque is a ready SELF-cheque (sender == this wallet);
    // fall back to any ready bundle if the address compare is finicky.
    const distress = cheques.find(c => c.ready && c.sender === ownAddr)
                  || cheques.find(c => c.ready);
    if (distress) { chequeId = distress.chequeId; break; }
    await sleep(params.pollIntervalMs || 250);
  }
  if (!chequeId) {
    throw new Error('Finish recovery: no distress cheque ready yet — re-anchor first, then wait for its dust cheque to arrive.');
  }
  const r = await redeem(wallet, transport, chequeId, params, onStep);
  wallet.clearHibernation();   // §2: mirror CL5's hibernation clear locally
  return { ...r, chequeId, hibernationUntil: 0 };
}

// YPX-022 RECALL (repurposed 2026-07-07) — retract a COMPLETED but
// UNDELIVERED payment (money RECOVERED, unlike heal/burn). recallFund opens
// the recall RESERVATION at Nabla FIRST (consume-once, §2.2.1: requires a
// completion-registered + NotRedeemed txid aged into the recall window; the
// cheque stays redeemable and a racing redeem WINS until the witnessed
// kind=Recall self-send commits at hibernation-entry), then drives that
// self-send (no debit). commitRecall persists the recall record + the
// hibernation stamp. After this the wallet HIBERNATES until recallComplete
// redeems the recall cheque (the only balance write: B−A + A = B).
export async function recall(wallet, transport, params, onStep) {
  const o = await wallet.recallFund(transport, params, onStep || null);
  stashOods(wallet, o);   // §8.2: the round's fresh reading — the completion redeem NEEDS it (§2.2.2)
  wallet.commitRecall(
    hexToBytes(o.producedStateIdHex),
    o.newBalance,       // BigInt
    o.newWalletSeq,     // BigInt
    o.receiptCbor,
    o.factChainCbor,
    o.hibernationUntil, // recall stamps RECALL_HIBERNATION_WINDOW
    hexToBytes(o.recalledTxidHex),
    hexToBytes(o.recalledStateIdHex),
    o.recallAmount,
    o.recallTick,
  );
  recordHistory(wallet, o.txidHex, 'Recall', 0n, '', 'recall');
  return {
    txid: o.txidHex,
    recalledTxid: o.recalledTxidHex,
    recallAmount: o.recallAmount,
    newBalance: o.newBalance,   // unchanged — recall never debits
    hibernationUntil: o.hibernationUntil,
    registered: o.registered,
    balance: wallet.balance,
  };
}

// YPX-022 completion — the same shape as halComplete (§2: the redeem IS the
// completion): redeem the recall self-cheque, mirror CL5's hibernation clear
// locally, and fill recall_cheque_id on the wallet's recall record.
export async function recallComplete(wallet, transport, params, onStep) {
  const r = await halComplete(wallet, transport, params, onStep);
  try {
    // Fill recall_cheque_id on the row this completion redeemed. The
    // hibernation gate makes >1 open recall impossible in practice (a
    // second recall can't start until this one completes), so an
    // unambiguous single open row is the expected case — fill it. If
    // bookkeeping ever disagrees (multiple open rows), fill NOTHING
    // rather than guess: an unfilled row only costs a later manual
    // markRecallCompleted, a wrongly-filled one corrupts the audit row.
    const open = (wallet.recallRecords() || []).filter(x => !x.recallChequeId);
    if (open.length === 1) {
      wallet.markRecallCompleted(open[0].recalledTxidHex, String(r.chequeId || ''));
    } else if (open.length > 1) {
      console.warn('[axiom] recallComplete: ' + open.length + ' open recall rows — none auto-filled');
    }
  } catch (_) { /* bookkeeping only — never fail the committed redeem */ }
  return r;
}

function sleep(ms) { return new Promise(res => setTimeout(res, ms)); }

// Shared body for heal / HAL re-anchor — both are key-proved validator-
// witnessed self-sends with no counterparty value, the same Fund → commitHeal
// shape. (HAL completion is NOT here — §2 makes it a redeem; see halComplete.)
// `fundFn` is the WASM method name, `histType`/`histRef` the History row labels.
async function healLike(wallet, fundFn, histType, histRef, transport, params, onStep) {
  const o = await wallet[fundFn](transport, params, onStep || null);
  stashOods(wallet, o);
  wallet.commitHeal(
    hexToBytes(o.producedStateIdHex),
    o.newBalance,    // BigInt
    o.newWalletSeq,  // BigInt
    o.receiptCbor,
    o.factChainCbor,
    o.clearClara,
    o.hibernationUntil, // YPX-020: re-anchor stamps the lock; heal/complete clear it
  );
  // Self-send (no counterparty value transfer) — record amount 0 so the
  // History view renders it as "<label> —".
  recordHistory(wallet, o.txidHex, histType, 0n, '', histRef);
  return {
    txid: o.txidHex,
    newBalance: o.newBalance,
    registered: o.registered,
    clearClara: o.clearClara,
    hibernationUntil: o.hibernationUntil,
    balance: wallet.balance,
  };
}

// Append a TxRecord via the SDK so it persists to history.cbor and shows in
// the History tab. Best-effort: a history-write failure must never fail the
// (already-committed) protocol op.
function recordHistory(wallet, txid, type, amount, counterparty, reference, feeBreakdown = []) {
  try {
    wallet.appendHistory(
      String(txid || ''),
      type,
      BigInt(amount),
      counterparty || '',
      BigInt(Math.floor(Date.now() / 1000)),
      reference || null,
      feeBreakdown || [],
    );
  } catch (e) {
    console.warn('[axiom] history record failed', e);
  }
}

function hexToBytes(hex) {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substr(i * 2, 2), 16);
  }
  return out;
}
