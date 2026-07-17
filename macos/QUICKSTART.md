# AxiomWallet — `@axiom.internal` dev access

The `@axiom.internal` namespace is the dev test network. Register a
wallet with any `something@axiom.internal` email and you get:

- A one-time **1 AXC airdrop** from the dev pool (1,000,000 AXC
  total, quarantined from the public 100M production supply)
- A real seat on the validator mesh — your TXs are witnessed by the
  same k=3 validators production runs
- Visibility into the per-validator dashboards, the global mesh
  graph, and your own FACT chain as it grows

This is enough to exercise every real surface of the protocol: send,
receive, redeem, register at Nabla, S-ABR overlap, heal, scar burn —
nothing is mocked.

**Class isolation.** dev-AXC stays inside `@axiom.internal`. Sends to
any other domain are rejected by Rule R1 at `validate_transaction`,
and the public 100M production pool cannot receive dev cheques. So
test wallets transact only among each other.

## Register

1. Open AxiomWallet → onboarding
2. Email: `you@axiom.internal` (any local-part you want; the address
   is yours as long as you hold the wallet key)
3. Set an app password + wallet key
4. Tap **Claim 1 AXC** on the Overview screen

Three validators witness the genesis self-send, three cheques arrive
via AxiomKiddo, the wallet auto-redeems. Balance lands at **0.997 AXC**
(0.3% receiver-pays fee across the k=3 witnesses).

## Once funded, you can

- **Send** to any other `*@axiom.internal` address (and only those —
  see class isolation above). Witness round runs
  serially across 3 validators; final receipt lands in your Activity
  view. The recipient won't see funds until they open their wallet
  and redeem.

- **Receive** — three cheques arrive in your inbox via AxiomKiddo
  (the mail courier). Open the Receive tab, tap the bundle, Redeem.

- **Watch the mesh** — `http://axiom-dev.mooo.com:8080/` shows the
  full validator topology + live witness counts. Each penguin has
  its own cockpit at `:7700`–`:7709` showing per-validator state.

- **Inspect your own chain** — Settings → Diagnostics shows your
  FACT chain depth, S-ABR pointer, Nabla confirmation state, and
  every cheque the wallet has touched.

- **Read the protocol live** — every cheque and witness response in
  your maildir is a CBOR envelope you can decode with any cbor
  inspector. The wire format is the Yellow Paper, on the wire.

## Concepts to know

- **Cheque** — validator-signed promise of AXC, addressed to the receiver. k=3 cheques constitute a redeemable bundle.
- **k=3** — three validators independently witness every TX
- **FACT chain** — your wallet's tamper-evident transaction history; depth gates compression and heal
- **Nabla** — citizen layer that publishes validator state, verifies cheques, gates double-redeem
- **dev-AXC** — `@axiom.internal` class, quarantined from the public 100M production supply; only flows among `@axiom.internal` addresses
- **Receiver-pays fee** — 0.1% per witness × k=3 = 0.3% taken from the recipient at redeem

## Limits

- One genesis claim per email address (the chain enforces this)
- Wallet key is unrecoverable — back it up
- Dev pool is finite (1M AXC across all testers) — be considerate
- Test network: occasional env wipes may reset balances

## When something looks off

| Symptom | What it means |
|---|---|
| "Nabla unreachable" | AxiomKiddo isn't running, or `axiom-dev.mooo.com` is down |
| Send stuck at "Witnessing…" | Validators are slow; wait 60s before retrying |
| Receive shows a 1-of-3 ghost cheque | Already-redeemed orphan; refresh and the SDK auto-filters it |
| Balance doesn't add up | Compare wallet balance against `last_receipt.state_hash` via Diagnostics |
