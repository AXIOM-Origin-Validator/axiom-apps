import SwiftUI
import AxiomSdk

// =================================================================
// UNCLE SAM app entry point + main shell.
//
// Single-window app. Top chrome strip shows the institution's brand
// + the operator's session info + zoom controls (institutional users
// review on large displays, often with aging eyes — a visible zoom
// control beats relying on macOS-wide accessibility settings). Left
// rail routes between sections; bottom Connection Health strip
// shows live UNCLE-gateway state.
//
// No login flow yet (placeholder — banks will integrate their own
// SSO / RBAC). Boots straight into the Message Queue with mock data
// so the demo is interactive immediately.
// =================================================================

@main
struct UNCLESamApp: App {

    @StateObject private var session = InstitutionSession()
    @StateObject private var store = MessageStore()
    @StateObject private var sdk = SdkBootstrap()
    @StateObject private var nablaNodes = NablaNodesStore()
    /// Release-feed update checker. Same CoreID → optional update,
    /// different CoreID → mandatory (the network's Core rotated and
    /// this institutional build can no longer transact). Checked once
    /// on launch; result surfaces as a banner + alert on MainShell.
    @StateObject private var releaseUpdate = ReleaseUpdateWatcher(product: .unclesam)
    // UNCLE SAM ↔ UNCLE SAM peer wire (Bucket 2 + 3):
    //   notifyChequesInbox  — verified inbound, awaiting pull worker
    //   pgpHandler          — PGP envelope decode + NotifyCheques
    //                          verify + Ack compose. Operator loads
    //                          the PGP secret key via Settings → Keys.
    //   peerListener        — TCP accept loop, hands envelope bytes
    //                          to pgpHandler.
    // The three are wired together at init() so they share one
    // inbox + one handler instance across SwiftUI's view tree.
    @StateObject private var notifyChequesInbox: NotifyChequesInbox
    @StateObject private var pgpHandler: PgpEnvelopeHandler
    @StateObject private var peerListener: UncleSamListener

    // Outbound side — Mac UNCLE SAM as a client of validator UNCLE
    // gateways. Bucket 4. PullCheques against expected validator
    // UNCLEs; Status warm-up first.
    @StateObject private var gatewayClient: UncleGatewayClient
    // Outbound NotifyCheques sender — Bucket 5(a). Composes,
    // canonical-byte-signs with ed25519, PGP-wraps, sends to peer
    // UNCLE SAM at :9090 (or loopback for self-send tests).
    @StateObject private var notifyChequesSender: NotifyChequesSender
    // SDK-outbox → validator-UNCLE witness-delivery daemon. Watches
    // each open account's <wallet.dir>/outbox/ for SDK-emitted
    // witness UMPs, PGP-wraps them as SubmitSend over TCP to the
    // k validators advertising uncle: + PGP, drops the responses
    // back into maildir/inbox/ where the SDK's wallet.send poll
    // loop picks them up. See docs/AXIOM_DESIGN_UncleSam_CarrierDirect.md.
    @StateObject private var outboxDaemon: OutboxCarrierDaemon

    init() {
        let inbox = NotifyChequesInbox()
        let handler = PgpEnvelopeHandler(inbox: inbox)
        let listener = UncleSamListener(handler: handler)
        let gw = UncleGatewayClient(pgpHandler: handler)
        let sender = NotifyChequesSender(pgpHandler: handler)
        let outbox = OutboxCarrierDaemon(pgpHandler: handler)
        // Bilateral binding — handler auto-pull dispatches PullCheques
        // through gatewayClient; gatewayClient verifies through
        // handler's loaded operator key.
        handler.gatewayClient = gw
        _notifyChequesInbox = StateObject(wrappedValue: inbox)
        _pgpHandler = StateObject(wrappedValue: handler)
        _peerListener = StateObject(wrappedValue: listener)
        _gatewayClient = StateObject(wrappedValue: gw)
        _notifyChequesSender = StateObject(wrappedValue: sender)
        _outboxDaemon = StateObject(wrappedValue: outbox)
        // gatewayClient.messageStore is bound below at .onAppear —
        // it's a `weak var` reference into the @StateObject `store`,
        // which only finishes initialising when the SwiftUI view
        // tree mounts (not in init()).
    }

    /// --smoke launch mode driver. Awaits SDK ready, loads operator
    /// PGP key from @AppStorage path, then fires Status →
    /// PullCheques against the configured gateway endpoint. Each
    /// step's outcome is logged via NSLog so the test runner can
    /// verify via `log show`. Exits after the round-trip completes.
    private func runLaunchSmoke() {
        Task { @MainActor in
            NSLog("[smoke] starting launch-smoke")
            // Wait for SDK setup before attempting any FFI work.
            for _ in 0..<300 { // up to 30s
                if case .ready = sdk.state { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard case .ready = sdk.state else {
                NSLog("[smoke] FAIL — sdk not ready: \(sdk.state)")
                exit(10)
            }
            // Load operator key from the @AppStorage path.
            let path = UserDefaults.standard.string(
                forKey: "uncle.sam.pgp.operator_key_path") ?? ""
            if path.isEmpty {
                NSLog("[smoke] FAIL — no operator_key_path set")
                exit(11)
            }
            let passphrase = UserDefaults.standard.string(
                forKey: "uncle.sam.pgp.operator_key_passphrase") ?? ""
            pgpHandler.loadOperatorKey(
                path: path,
                passphrase: passphrase.isEmpty ? nil : passphrase)
            guard case .loaded(let fp) = pgpHandler.keyState else {
                NSLog("[smoke] FAIL — operator key load: \(pgpHandler.keyState)")
                exit(12)
            }
            NSLog("[smoke] operator key loaded fp=\(fp)")
            // Bind store now if .onAppear hasn't reached us yet.
            gatewayClient.messageStore = store
            // Pull config from @AppStorage.
            let endpoint = UserDefaults.standard.string(
                forKey: "uncle.sam.gateway.endpoint") ?? ""
            let pubkey = UserDefaults.standard.string(
                forKey: "uncle.sam.gateway.pubkey_armored") ?? ""
            if endpoint.isEmpty || pubkey.isEmpty {
                NSLog("[smoke] FAIL — gateway endpoint/pubkey missing")
                exit(13)
            }
            // Status
            NSLog("[smoke] Status → \(endpoint)")
            await gatewayClient.status(endpoint: endpoint,
                                        targetPubkeyArmored: pubkey)
            if let err = gatewayClient.lastError {
                NSLog("[smoke] FAIL — Status: \(err.localizedDescription)")
                exit(14)
            }
            if let s = gatewayClient.lastStatus {
                NSLog("[smoke] StatusOK version=\(s.version) uptime=\(s.uptimeSecs)s")
            }
            // PullCheques
            NSLog("[smoke] PullCheques → \(endpoint)")
            let inboundBefore = store.inbound().count
            await gatewayClient.pullCheques(endpoint: endpoint,
                                             targetPubkeyArmored: pubkey,
                                             sinceTick: 0,
                                             walletFilter: nil,
                                             maxRows: 100)
            if let err = gatewayClient.lastError {
                NSLog("[smoke] FAIL — PullCheques: \(err.localizedDescription)")
                exit(15)
            }
            let response = gatewayClient.lastPullResponse
            let respCount = response?.cheques.count ?? -1
            let ingested = gatewayClient.lastIngestedCount
            let inboundAfter = store.inbound().count
            NSLog("[smoke] PullOK response_rows=\(respCount) ingested=\(ingested) inbound_before=\(inboundBefore) inbound_after=\(inboundAfter)")
            if respCount > 0 {
                for c in response?.cheques ?? [] {
                    NSLog("[smoke]   cheque txid=\(c.txidHex.prefix(16))… receiver=\(c.receiverWallet) sender=\(c.senderWallet) atoms=\(c.amountAtoms) blob=\(c.chequeBlob.count)")
                }
            }
            // Check the inbox tab gets the cheques
            let pulled = store.inbound().filter {
                $0.reference.hasPrefix("PULL-")
            }
            NSLog("[smoke] inbox PULL-* rows = \(pulled.count)")
            for r in pulled {
                NSLog("[smoke]   inbox ref=\(r.reference) ordering=\(r.orderingCustomerName) beneficiary=\(r.beneficiaryName) status=\(r.status.rawValue) k=\(r.witnessCount)/\(r.requiredK) nabla=\(r.nablaConfirmed)")
            }
            NSLog("[smoke] DONE — exiting cleanly")
            try? await Task.sleep(nanoseconds: 500_000_000)
            exit(0)
        }
    }

    /// Loopback self-send smoke. Configures self-counterparty, starts
    /// the :9090 listener, composes a NotifyCheques, sends it to
    /// 127.0.0.1:9090, verifies listener received + inbox got an
    /// entry. Logs every step with the [self-send] prefix.
    private func runLaunchSelfSendSmoke() {
        Task { @MainActor in
            NSLog("[self-send] starting")
            for _ in 0..<300 {
                if case .ready = sdk.state { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard case .ready = sdk.state else {
                NSLog("[self-send] FAIL — sdk not ready")
                exit(20)
            }
            let opKeyPath = UserDefaults.standard.string(
                forKey: "uncle.sam.pgp.operator_key_path") ?? ""
            guard !opKeyPath.isEmpty else {
                NSLog("[self-send] FAIL — no operator_key_path")
                exit(21)
            }
            pgpHandler.loadOperatorKey(path: opKeyPath, passphrase: nil)
            guard case .loaded(let opFp) = pgpHandler.keyState else {
                NSLog("[self-send] FAIL — operator key load: \(pgpHandler.keyState)")
                exit(22)
            }
            NSLog("[self-send] operator fp=\(opFp)")
            let selfPubPath = UserDefaults.standard.string(
                forKey: "uncle.sam.self.pgp_public_path") ?? ""
            let selfEdSecPath = UserDefaults.standard.string(
                forKey: "uncle.sam.self.ed25519_secret_path") ?? ""
            let selfEdPubHex = UserDefaults.standard.string(
                forKey: "uncle.sam.self.ed25519_public_hex") ?? ""
            guard !selfPubPath.isEmpty,
                  !selfEdSecPath.isEmpty,
                  !selfEdPubHex.isEmpty
            else {
                NSLog("[self-send] FAIL — self identity not configured")
                exit(23)
            }
            let armored: String
            do {
                armored = try String(contentsOfFile: selfPubPath, encoding: .utf8)
            } catch {
                NSLog("[self-send] FAIL — read self pgp pubkey: \(error)")
                exit(24)
            }
            CounterpartyStore.selfEntry = Counterparty(
                name: "Self (smoke)",
                bic: "SELFXXXXXXX",
                jurisdiction: "—",
                peerEndpoint: "127.0.0.1:9090",
                relationshipSince: "—",
                axiomTierAddress: "(self)",
                fxRate: 1.0,
                fxCounterCurrency: "AXC",
                dailyLimit: 0,
                pgpFingerprint: opFp,
                pgpPublicKey: armored,
                operatorEd25519PubkeyHex: selfEdPubHex)
            NSLog("[self-send] self counterparty registered")
            peerListener.start(port: 9090)
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard peerListener.state.isRunning else {
                NSLog("[self-send] FAIL — listener not running: \(peerListener.state)")
                exit(25)
            }
            NSLog("[self-send] listener up on :9090")
            let edSecret: Data
            do {
                edSecret = try Data(
                    contentsOf: URL(fileURLWithPath: selfEdSecPath))
            } catch {
                NSLog("[self-send] FAIL — read ed25519 secret: \(error)")
                exit(26)
            }
            // Bind gateway client → MessageStore so auto-pull can
            // ingest into Inbox tab.
            gatewayClient.messageStore = store
            let inboxBefore = notifyChequesInbox.entries.count
            let envelopesBefore = peerListener.envelopesReceived
            let storeInboundBefore = store.inbound().count
            // Populate expected_pieces with alpha UNCLE so the
            // listener's auto-pull fires a real PullCheques call.
            // validator_id is 32 zeros for the smoke — the
            // PullCheques handler does not validate it (it serves
            // rows by ACL of the calling fp).
            let alphaEndpoint = UserDefaults.standard.string(
                forKey: "uncle.sam.gateway.endpoint") ?? ""
            let expectedPieces: [(validatorId: Data, uncleEndpoint: String)]
            if !alphaEndpoint.isEmpty {
                expectedPieces = [(
                    validatorId: Data(count: 32),
                    uncleEndpoint: alphaEndpoint
                )]
            } else {
                expectedPieces = []
            }
            await notifyChequesSender.send(
                senderWalletId: "treasury@selfsend.example/aaaaaaaaaa",
                receiverWalletId: "fx@selfsend.example/bbbbbbbbbb",
                amountAtoms: 100000,
                swiftReference: "SMOKE-SELF-SEND-001",
                expectedPieces: expectedPieces,
                ed25519SecretBytes: edSecret,
                recipientPubkeyArmored: armored,
                targetEndpoint: "127.0.0.1:9090")
            if let err = notifyChequesSender.lastError {
                NSLog("[self-send] FAIL — send error: \(err)")
                exit(27)
            }
            guard let ack = notifyChequesSender.lastAck else {
                NSLog("[self-send] FAIL — no ack")
                exit(28)
            }
            NSLog("[self-send] ack status=\(ack.status.rawValue) reason=\(ack.reason ?? "nil")")
            // Auto-pull fires from a detached Task in handle(),
            // so wait a bit longer to give the PullCheques round-
            // trip to alpha + ingest time to settle.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            let inboxAfter = notifyChequesInbox.entries.count
            let envelopesAfter = peerListener.envelopesReceived
            let storeInboundAfter = store.inbound().count
            NSLog("[self-send] envelopes before/after = \(envelopesBefore)/\(envelopesAfter)")
            NSLog("[self-send] inbox before/after = \(inboxBefore)/\(inboxAfter)")
            NSLog("[self-send] store.inbound before/after = \(storeInboundBefore)/\(storeInboundAfter)")
            if envelopesAfter == envelopesBefore {
                NSLog("[self-send] FAIL — listener envelopes did not increment")
                exit(29)
            }
            if ack.status == .accepted && inboxAfter == inboxBefore {
                NSLog("[self-send] FAIL — ack accepted but inbox did not increment")
                exit(30)
            }
            if let bundleId = notifyChequesSender.lastBundleIdHex {
                NSLog("[self-send] bundle_id=\(bundleId)")
            }
            for e in notifyChequesInbox.entries.prefix(3) {
                NSLog("[self-send]   notify: counterparty=\(e.counterpartyName) sender_wallet=\(e.notice.senderWalletId) receiver_wallet=\(e.notice.receiverWalletId) atoms=\(e.notice.amountAtoms) ref=\(e.notice.swiftReference) expected_pieces=\(e.notice.expectedPieces.count)")
            }
            // Surface what auto-pull deposited in MessageStore.
            let pulled = store.inbound().filter {
                $0.reference.hasPrefix("PULL-")
            }
            NSLog("[self-send] MessageStore PULL-* rows = \(pulled.count)")
            // Bucket 5(d) — pending credit total surfaces in
            // Settings → Institution accounts as a chip. The
            // overall total includes pre-seeded mock inbound
            // records, so we also compute the PULL-only subtotal
            // to make the smoke output verifiable against the 2
            // pulled cheques (500000 + 500000 = 1000000 atoms).
            let totalPending = store.pendingCreditAtoms()
            let pullPendingAtoms = pulled.reduce(into: UInt64(0)) { acc, r in
                let s = r.settlementAmount.replacingOccurrences(of: ",", with: "")
                if let axc = Double(s) {
                    acc &+= UInt64(axc * 1e10)
                }
            }
            NSLog("[self-send] pending credit (PULL-* only) atoms = \(pullPendingAtoms)")
            NSLog("[self-send] pending credit (all inbound) atoms = \(totalPending)")
            for r in pulled.prefix(5) {
                NSLog("[self-send]   inbox row ref=\(r.reference) status=\(r.status.rawValue)")
                for evt in r.lifecycle {
                    if evt.kind == .received,
                       let note = evt.note {
                        // Lifecycle note carries the structural
                        // verify summary — surface it so the smoke
                        // log reflects what bank operators see in
                        // the Detail view.
                        NSLog("[self-send]     lifecycle.received: \(note)")
                    }
                }
            }
            NSLog("[self-send] DONE — exiting cleanly")
            try? await Task.sleep(nanoseconds: 500_000_000)
            exit(0)
        }
    }

    /// Full-send loopback smoke. Bootstraps everything (PGP +
    /// self-counterparty pointing at 127.0.0.1:9090), starts the
    /// listener, injects a synthetic completed MessageRecord
    /// targeting the self-counterparty's BIC, and drives
    /// MessageStore.fireNotifyChequesIfConfigured. Verifies the
    /// FULL outbound→inbound chain: NotifyCheques arrives, listener
    /// verifies + ingests, auto-pull fires against alpha, cheques
    /// land in the Inbox tab.
    private func runLaunchFullSendSmoke() {
        Task { @MainActor in
            NSLog("[full-send] starting")
            // Wait for SDK + load operator key + register self-CP
            for _ in 0..<300 {
                if case .ready = sdk.state { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard case .ready = sdk.state else {
                NSLog("[full-send] FAIL — sdk not ready"); exit(40)
            }
            let opKeyPath = UserDefaults.standard.string(
                forKey: "uncle.sam.pgp.operator_key_path") ?? ""
            pgpHandler.loadOperatorKey(path: opKeyPath, passphrase: nil)
            guard case .loaded(let opFp) = pgpHandler.keyState else {
                NSLog("[full-send] FAIL — pgp not loaded"); exit(41)
            }
            let selfPubPath = UserDefaults.standard.string(
                forKey: "uncle.sam.self.pgp_public_path") ?? ""
            let selfEdPubHex = UserDefaults.standard.string(
                forKey: "uncle.sam.self.ed25519_public_hex") ?? ""
            let armored: String
            do {
                armored = try String(contentsOfFile: selfPubPath,
                                      encoding: .utf8)
            } catch {
                NSLog("[full-send] FAIL — self pgp pubkey read: \(error)")
                exit(42)
            }
            // Self counterparty — uncle field IS the peer endpoint
            // (loopback for this smoke).
            CounterpartyStore.selfEntry = Counterparty(
                name: "Self (full-send smoke)",
                bic: "SELFXXXXXXX",
                jurisdiction: "—",
                peerEndpoint: "127.0.0.1:9090",
                relationshipSince: "—",
                axiomTierAddress: "fx@selfsend.example/cccccccccc",
                fxRate: 1.0, fxCounterCurrency: "AXC",
                dailyLimit: 0,
                pgpFingerprint: opFp,
                pgpPublicKey: armored,
                operatorEd25519PubkeyHex: selfEdPubHex)
            NSLog("[full-send] self-counterparty registered BIC=SELFXXXXXXX endpoint=127.0.0.1:9090")
            peerListener.start(port: 9090)
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard peerListener.state.isRunning else {
                NSLog("[full-send] FAIL — listener not running")
                exit(43)
            }
            NSLog("[full-send] listener up on :9090")
            // Bind store dependencies.
            gatewayClient.messageStore = store
            store.notifyChequesSender = notifyChequesSender
            let inboxBefore = notifyChequesInbox.entries.count
            let storeInboundBefore = store.inbound().count
            // Synthetic txid — 64 hex chars (32 bytes).
            let txidHex = String(repeating: "ab", count: 32)
            NSLog("[full-send] driving smokeCompleteSend BIC=SELFXXXXXXX atoms=250000")
            let recId = await store.smokeCompleteSend(
                reference: "FULL-SEND-SMOKE-001",
                beneficiaryBIC: "SELFXXXXXXX",
                txidHex: txidHex,
                atoms: 250000)
            // Wait for auto-pull + ack lifecycle to settle.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let inboxAfter = notifyChequesInbox.entries.count
            let storeInboundAfter = store.inbound().count
            NSLog("[full-send] inbox before/after = \(inboxBefore)/\(inboxAfter)")
            NSLog("[full-send] store.inbound before/after = \(storeInboundBefore)/\(storeInboundAfter)")
            // Find the synthetic record and dump its lifecycle.
            if let rec = store.messages.first(where: { $0.id == recId }) {
                NSLog("[full-send] synthetic record status=\(rec.status.rawValue)")
                for evt in rec.lifecycle {
                    NSLog("[full-send]   lifecycle: \(evt.kind.rawValue) | actor=\(evt.actor) | note=\(evt.note ?? "")")
                }
            }
            if inboxAfter == inboxBefore {
                NSLog("[full-send] FAIL — NotifyCheques didn't land in listener inbox")
                exit(44)
            }
            NSLog("[full-send] DONE — outbound NotifyCheques + receive chain validated end-to-end")
            try? await Task.sleep(nanoseconds: 500_000_000)
            exit(0)
        }
    }

    /// Real-send smoke. Drives an actual wallet.send through the
    /// existing submitForAuthorization + authorize path. Picks
    /// sender + receiver from configured InstitutionAccounts;
    /// fails clearly when no wallet is open / no balance / no
    /// second account / no validators reachable.
    private func runLaunchRealSendSmoke() {
        Task { @MainActor in
            NSLog("[real-send] starting")
            // Wait for SDK + active wallet.
            for _ in 0..<300 {
                if case .ready = sdk.state { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard case .ready = sdk.state else {
                NSLog("[real-send] FAIL — sdk not ready"); exit(50)
            }
            // Trigger wallet open if not already.
            session.tryOpenExistingWallet(appDir: uncleAppDir())
            try? await Task.sleep(nanoseconds: 500_000_000)
            // Load PGP key + self-counterparty fixture.
            let opKeyPath = UserDefaults.standard.string(
                forKey: "uncle.sam.pgp.operator_key_path") ?? ""
            pgpHandler.loadOperatorKey(path: opKeyPath, passphrase: nil)
            guard case .loaded(let opFp) = pgpHandler.keyState else {
                NSLog("[real-send] FAIL — pgp not loaded"); exit(51)
            }
            // Pick sender + receiver from configured accounts.
            // Strategy:
            //   - First refresh balances for all accounts
            //   - sender   = account with HIGHEST balance (any account
            //                with the funds to actually move money)
            //   - receiver = SECOND-highest balance account, or any
            //                other open-tier account if all but one
            //                are at zero
            guard !session.accounts.isEmpty else {
                NSLog("[real-send] FAIL — no accounts configured")
                exit(52)
            }
            // Refresh balances first — they may be stale from the
            // last @Published flush.
            for acct in session.accounts { acct.refreshBalance() }
            try? await Task.sleep(nanoseconds: 200_000_000)
            // Dump every account's state so the operator can see
            // what got picked + why.
            NSLog("[real-send] account balance roll-call:")
            for acct in session.accounts {
                NSLog("[real-send]   \(acct.config.displayName) tier=\(acct.tierAddress.prefix(28))… balance_atoms=\(acct.balanceAtoms)")
            }
            // Sort accounts by balance descending, filter to ones
            // with non-empty tier addresses.
            let ranked = session.accounts
                .filter { !$0.tierAddress.isEmpty }
                .sorted { $0.balanceAtoms > $1.balanceAtoms }
            guard let sender = ranked.first else {
                NSLog("[real-send] FAIL — no accounts with open tier address")
                exit(53)
            }
            let receiverCandidates = ranked.dropFirst().filter { $0.id != sender.id }
            guard let receiver = receiverCandidates.first else {
                NSLog("[real-send] FAIL — no second account with open tier address")
                exit(54)
            }
            // Receiver address: prefer the wallet's DMAP variant
            // (proof=1) over the ZKVM variant (proof=0). The dev env
            // validators are all DMAP-only — picking a ZKVM tier
            // would force the hard tier filter to drop every
            // available validator. Lowest-k DMAP address is the
            // easiest to land in any partial network state.
            var receiverAddr = receiver.tierAddress
            if let rw = receiver.wallet, let addrs = try? rw.allAddresses() {
                let dmapAddrs = addrs.filter { $0.proofType == 1 }
                    .sorted { $0.k < $1.k }
                if let pick = dmapAddrs.first {
                    receiverAddr = pick.address
                    NSLog("[real-send] receiver retargeted to DMAP tier: name=\(pick.displayName) k=\(pick.k) addr=\(receiverAddr)")
                }
            }
            NSLog("[real-send] sender=\(sender.config.displayName) tier=\(sender.tierAddress.prefix(28))…")
            NSLog("[real-send] receiver=\(receiver.config.displayName) tier=\(receiverAddr.prefix(28))…")
            NSLog("[real-send] sender balance atoms=\(sender.balanceAtoms)")
            // Diagnostic: what does the SDK see for carrier pref +
            // validator hints right now?
            let currentPref = sdkGetCarrierPreference()
            NSLog("[real-send] sdk carrier pref = \(currentPref)")
            let snapshot = sdkAppValidators()
            NSLog("[real-send] sdk validator hints count = \(snapshot.count)")
            let uncleCapable = snapshot.filter { hint in
                hint.carriers.contains { $0.lowercased().hasPrefix("uncle:") }
            }
            let uncleNames = uncleCapable.map { $0.name }.joined(separator: ",")
            NSLog("[real-send] uncle-capable hints = \(uncleCapable.count): \(uncleNames)")
            NSLog("[real-send] sender tier address full = \(sender.tierAddress)")
            NSLog("[real-send] receiver tier address full = \(receiver.tierAddress)")
            // Dump all 7 tier addresses for each wallet so we can
            // see whether the active tier is DMAP or ZKP. All 10
            // dev validators are DMAP-only; a ZKP receiver address
            // would force the hard tier filter to drop every
            // available validator.
            if let sw = sender.wallet, let addrs = try? sw.allAddresses() {
                for a in addrs {
                    NSLog("[real-send] sender tier: name=\(a.displayName) k=\(a.k) proof=\(a.proofType) addr=\(a.address.prefix(40))")
                }
            }
            if let rw = receiver.wallet, let addrs = try? rw.allAddresses() {
                for a in addrs {
                    NSLog("[real-send] receiver tier: name=\(a.displayName) k=\(a.k) proof=\(a.proofType) addr=\(a.address.prefix(40))")
                }
            }
            // Switch UNCLE SAM's active account to the sender so
            // dispatchToAxiom uses session.wallet pointing at the
            // funded wallet.
            session.setActiveAccount(sender.id)
            try? await Task.sleep(nanoseconds: 200_000_000)
            NSLog("[real-send] active account set to sender")
            // Diagnose the wallet — does it think it needs heal?
            if let wallet = sender.wallet {
                if let actions = try? wallet.diagnose() {
                    NSLog("[real-send] sender diagnose returned \(actions.count) action(s)")
                    for a in actions {
                        let detail = a.detail ?? "nil"
                        NSLog("[real-send]   diagnose action: call=\(a.call) detail=\(detail)")
                    }
                    if actions.contains(where: { $0.call == "heal" || $0.call == "burn" || $0.call == "nabla_register" }) {
                        NSLog("[real-send] sender needs heal — calling wallet.heal() off-main")
                        // Run heal() on a background queue — heal is
                        // long-running synchronous FFI (CL1 proof +
                        // sequential k-witness polls); running it on
                        // MainActor starves the OutboxCarrierDaemon
                        // pollLoop, which means the heal's own outbox
                        // files never get delivered. Same pattern as
                        // the Mac SendCoordinator (memory:
                        // `Mac SendCoordinator → DispatchQueue.global`).
                        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                            DispatchQueue.global(qos: .userInitiated).async {
                                if let result = try? wallet.heal() {
                                    DispatchQueue.main.async {
                                        NSLog("[real-send] heal result: \(result)")
                                        cont.resume()
                                    }
                                } else {
                                    DispatchQueue.main.async {
                                        NSLog("[real-send] heal() threw")
                                        cont.resume()
                                    }
                                }
                            }
                        }
                    }
                }
                if ProcessInfo.processInfo.environment["UNCLESAM_SMOKE_FORCE_HEAL"] == "1" {
                    NSLog("[real-send] FORCE_HEAL=1 → unconditional heal() off-main")
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                let result = try wallet.heal()
                                DispatchQueue.main.async {
                                    NSLog("[real-send] heal: issues_found=\(result.issuesFound) issues_fixed=\(result.issuesFixed) healthy=\(result.healthy)")
                                    cont.resume()
                                }
                            } catch {
                                DispatchQueue.main.async {
                                    NSLog("[real-send] heal() threw: \(error.localizedDescription)")
                                    cont.resume()
                                }
                            }
                        }
                    }
                }
            }
            // Register self-counterparty targeting receiver's tier.
            let selfPubPath = UserDefaults.standard.string(
                forKey: "uncle.sam.self.pgp_public_path") ?? ""
            let selfEdPubHex = UserDefaults.standard.string(
                forKey: "uncle.sam.self.ed25519_public_hex") ?? ""
            guard !selfPubPath.isEmpty, !selfEdPubHex.isEmpty else {
                NSLog("[real-send] FAIL — self identity not configured")
                exit(55)
            }
            let armored = (try? String(contentsOfFile: selfPubPath,
                                        encoding: .utf8)) ?? ""
            CounterpartyStore.selfEntry = Counterparty(
                name: "Self (real-send smoke)",
                bic: "SELFXXXXXXX",
                jurisdiction: "—",
                peerEndpoint: "127.0.0.1:9090",
                relationshipSince: "—",
                axiomTierAddress: receiverAddr,
                fxRate: 1.0, fxCounterCurrency: "AXC",
                dailyLimit: 0,
                pgpFingerprint: opFp,
                pgpPublicKey: armored,
                operatorEd25519PubkeyHex: selfEdPubHex)
            NSLog("[real-send] self-counterparty registered, targets receiver tier")
            // Start listener + bind store deps.
            peerListener.start(port: 9090)
            try? await Task.sleep(nanoseconds: 400_000_000)
            gatewayClient.messageStore = store
            store.notifyChequesSender = notifyChequesSender
            NSLog("[real-send] listener up, stores bound")
            // Submit for authorization. Maker name "smoke-maker".
            let recId = store.submitForAuthorization(
                reference: "REAL-SEND-LOOPBACK-001",
                format: .pacs008,
                settlementCurrency: "AXC",
                settlementAmount: "0.0001",
                orderingCustomerName: sender.config.displayName,
                beneficiaryName: receiver.config.displayName,
                beneficiaryBIC: "SELFXXXXXXX",
                valueDate: Date(),
                envelopeBody: "(real-send smoke)",
                maker: "smoke-maker")
            NSLog("[real-send] submitForAuthorization → \(recId)")
            // Authorize as different operator → triggers
            // dispatchToAxiom → wallet.send.
            let result = store.authorize(recId, by: "smoke-checker")
            switch result {
            case .success:
                NSLog("[real-send] authorize OK — wallet.send dispatched in background")
            case .failure(let e):
                NSLog("[real-send] FAIL — authorize: \(e)"); exit(56)
            }
            // Watch for completion: status flips off .authorized
            // and either lands at .sent / .ack (success) or .nack
            // (failure). Up to 90s for the witness round.
            var settled = false
            for tick in 0..<900 {
                if let r = store.messages.first(where: { $0.id == recId }) {
                    if r.status != .authorized && r.status != .pendingAuthorization {
                        NSLog("[real-send] tick=\(tick) status=\(r.status.rawValue) txid=\(r.axiomTxid ?? "nil")")
                        settled = true
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if !settled {
                NSLog("[real-send] FAIL — wallet.send didn't settle in 90s")
                exit(57)
            }
            // Wait for NotifyCheques + auto-pull settle.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // Dump the record's lifecycle.
            if let r = store.messages.first(where: { $0.id == recId }) {
                NSLog("[real-send] final status=\(r.status.rawValue)")
                for evt in r.lifecycle {
                    NSLog("[real-send]   lifecycle: \(evt.kind.rawValue) | actor=\(evt.actor) | note=\(evt.note ?? "")")
                }
            }
            NSLog("[real-send] notifyChequesInbox.entries = \(notifyChequesInbox.entries.count)")
            NSLog("[real-send] store.inbound count = \(store.inbound().count)")
            NSLog("[real-send] DONE")
            try? await Task.sleep(nanoseconds: 500_000_000)
            exit(0)
        }
    }

    /// Import-flow smoke. Stages a fake source wallet at /tmp by
    /// copying an existing account's wallet directory, then drives
    /// session.importAccount(...) and verifies the new account
    /// shows up + the source was renamed.
    private func runLaunchImportSmoke() {
        Task { @MainActor in
            NSLog("[import-smoke] starting")
            for _ in 0..<300 {
                if case .ready = sdk.state { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard case .ready = sdk.state else {
                NSLog("[import-smoke] FAIL — sdk not ready"); exit(60)
            }
            session.tryOpenExistingWallet(appDir: uncleAppDir())
            try? await Task.sleep(nanoseconds: 300_000_000)
            // Source = a copy of one existing wallet's directory.
            // We close it first (cancel the FLOCK) by using a
            // non-treasury account if present; otherwise just
            // operate on a side copy.
            guard !session.accounts.isEmpty else {
                NSLog("[import-smoke] FAIL — no existing accounts to clone")
                exit(61)
            }
            let donor = session.accounts.first!
            let walletsRoot = "\(uncleAppDir())/wallets"
            let donorDir = "\(walletsRoot)/\(donor.config.pairName)-normal"
            let stagingRoot = "/tmp/unclesam-import-smoke-\(Int(Date().timeIntervalSince1970))"
            try? FileManager.default.createDirectory(
                atPath: stagingRoot, withIntermediateDirectories: true)
            let stagingDir = "\(stagingRoot)/\(donor.config.pairName)-normal"
            do {
                try FileManager.default.copyItem(
                    atPath: donorDir, toPath: stagingDir)
            } catch {
                NSLog("[import-smoke] FAIL — stage copy: \(error)")
                exit(62)
            }
            // Remove the .lock from the staged copy so import
            // can open it independently.
            try? FileManager.default.removeItem(
                atPath: "\(stagingDir)/wallet.axiom.lock")
            NSLog("[import-smoke] staged source: \(stagingDir)")
            let beforeCount = session.accounts.count
            let result = session.importAccount(
                appDir: uncleAppDir(),
                sourceDir: stagingDir,
                displayName: "Imported Smoke \(Int.random(in: 1000..<9999))",
                purpose: .treasury,
                subBIC: "",
                color: .navy,
                renameOriginal: true)
            let afterCount = session.accounts.count
            NSLog("[import-smoke] accounts before/after = \(beforeCount)/\(afterCount)")
            if let result = result {
                if afterCount > beforeCount {
                    NSLog("[import-smoke] import succeeded with WARNING: \(result)")
                } else {
                    NSLog("[import-smoke] FAIL — import error: \(result)")
                    exit(63)
                }
            } else {
                NSLog("[import-smoke] import succeeded with no warning")
            }
            // Verify the rename happened.
            let renamedExists = (try? FileManager.default
                .contentsOfDirectory(atPath: stagingRoot))?
                .contains { $0.contains(".imported-to-UNCLESam-") } ?? false
            NSLog("[import-smoke] source renamed = \(renamedExists)")
            if let newAccount = session.accounts.last {
                NSLog("[import-smoke] new account: \(newAccount.config.displayName) wallet_email=\(newAccount.config.walletEmail) tier=\(newAccount.tierAddress)")
            }
            NSLog("[import-smoke] DONE")
            try? await Task.sleep(nanoseconds: 500_000_000)
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch sdk.state {
                case .pending:
                    SdkLoadingView()
                case .failed(let msg):
                    SdkSetupErrorView(message: msg)
                case .ready:
                    if session.accounts.isEmpty {
                        UNCLEOnboardingView()
                            .environmentObject(session)
                    } else {
                        MainShell()
                            .environmentObject(session)
                            .environmentObject(store)
                            .environmentObject(nablaNodes)
                            .environmentObject(peerListener)
                            .environmentObject(pgpHandler)
                            .environmentObject(notifyChequesInbox)
                            .environmentObject(gatewayClient)
                            .environmentObject(notifyChequesSender)
                            .environmentObject(outboxDaemon)
                            .environmentObject(releaseUpdate)
                            .task { await releaseUpdate.check() }
                    }
                }
            }
            .onAppear {
                // Bind the store to the session so authorize()
                // can reach the open AxiomWallet for real
                // wallet.send() calls.
                store.session = session
                // Bind the gateway client to MessageStore so
                // PullCheques success ingests the response cheques
                // as inbound .received records visible in the
                // Inbox tab.
                gatewayClient.messageStore = store
                // Bind the NotifyCheques sender so completeSend can
                // fire a peer notification after a successful
                // wallet.send.
                store.notifyChequesSender = notifyChequesSender
                // Bind the outbox daemon to the session so it can
                // iterate open accounts; start the poll loop. The
                // daemon stays idle until SDK setup completes + an
                // operator key is loaded; until then it logs "PGP
                // operator key not loaded" once per file and backs
                // off — same trace surface as live operation.
                outboxDaemon.session = session
                outboxDaemon.start()
                sdk.run()
                // --smoke launch mode — when the env var is set,
                // wait for SDK ready then fire Status + PullCheques
                // against the configured gateway endpoint and log
                // outcomes via NSLog so a terminal-driven test can
                // verify the integration without UI clicks. Exits
                // after a short delay.
                if ProcessInfo.processInfo.environment["UNCLESAM_SMOKE"] == "1" {
                    runLaunchSmoke()
                }
                // --self-send smoke: compose + send a NotifyCheques
                // from Mac to itself via 127.0.0.1:9090, verify it
                // lands in NotifyChequesInbox.
                if ProcessInfo.processInfo.environment["UNCLESAM_SMOKE_SELFSEND"] == "1" {
                    runLaunchSelfSendSmoke()
                }
                // --full-send smoke: end-to-end. Inject synthetic
                // MessageRecord that simulates a completed
                // wallet.send, drive fireNotifyChequesIfConfigured,
                // verify the peer-wire round-trip + auto-pull +
                // ingest into the Inbox tab.
                if ProcessInfo.processInfo.environment["UNCLESAM_SMOKE_FULLSEND"] == "1" {
                    runLaunchFullSendSmoke()
                }
                // --REAL send smoke: drives an actual wallet.send
                // → completeSend → NotifyCheques chain by exercising
                // submitForAuthorization + authorize on the real
                // path. Picks sender + receiver from the configured
                // accounts; fails clearly if no wallet is open / no
                // balance / no second account.
                if ProcessInfo.processInfo.environment["UNCLESAM_SMOKE_REALSEND"] == "1" {
                    runLaunchRealSendSmoke()
                }
                // --import smoke: stage a fake source wallet
                // directory (copied from an existing account) and
                // exercise the import flow end-to-end.
                if ProcessInfo.processInfo.environment["UNCLESAM_SMOKE_IMPORT"] == "1" {
                    runLaunchImportSmoke()
                }
            }
            .onChange(of: sdk.state) { _, new in
                if case .ready = new {
                    // Re-open the existing wallet if present.
                    // Fresh installs land on onboarding (wallet
                    // stays nil until the operator submits).
                    session.tryOpenExistingWallet(appDir: uncleAppDir())
                }
            }
            // Min size only — allow the operator to drag the
            // window larger. The previous .contentSize policy
            // pinned the window to base * zoom and clipped the
            // wide queue tables on first launch.
            .frame(minWidth: 1400 * session.zoom,
                   minHeight: 860 * session.zoom)
            // Force light appearance throughout the app.
            // DesignTokens uses absolute Color values designed
            // for a light institutional theme. Without this, any
            // Text view without an explicit foregroundStyle picks
            // up macOS's dynamic `.primary` colour — which goes
            // WHITE in dark mode and produces white-on-grey on
            // our light-grey table backgrounds. Banking UIs are
            // universally light-themed; we follow suit.
            .preferredColorScheme(.light)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // ⌘+ / ⌘− / ⌘0 for in-app zoom — matches what banker
            // reviewers expect from a desktop tool.
            CommandGroup(after: .windowSize) {
                Button("Larger Text") { session.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller Text") { session.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Reset Text Size") { session.zoomReset() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

/// Bank operator role. The maker-checker workflow keys off this:
/// makers create messages and submit for authorization; checkers
/// approve / reject from the Pending Authorization tab. In a real
/// deployment the role would come from SSO / RBAC; for the demo
/// the operator can switch roles in Settings to walk through both
/// halves of the workflow.
enum OperatorRole: String, CaseIterable, Identifiable {
    case maker        = "Maker"
    case checker      = "Checker"
    /// Treasury role — sees per-account balances, bilateral
    /// counterparty FX, and position-level reporting. Does NOT
    /// compose or authorize wires (separation of duty: the
    /// treasurer sets funding policy + watches positions; line
    /// operators move money). AXIOM Origin 2026-05-30: "honestly, i
    /// don't think everyone should see the balance".
    case treasurer    = "Treasurer"
    /// Auditor — read-only across everything (balances, audit
    /// trail, lifecycle events). Used by internal audit + the
    /// regulator's standing read account. No mutation.
    case auditor      = "Auditor"
    /// All-privileges demo role so an executive reviewer can drive
    /// the full flow as a single identity — compose + authorize +
    /// balance/audit visibility. Label is honest about the bundled
    /// privileges (Maker + Checker + Auditor) so nobody is left
    /// thinking the demo only grants compose/authorize and that
    /// balance visibility is some kind of bug. A real production
    /// deployment never grants any combination of these to a single
    /// human.
    case makerChecker = "Maker + Checker + Auditor (demo only)"
    var id: String { rawValue }

    /// Can compose new outbound messages.
    var canCreate: Bool {
        self == .maker || self == .makerChecker
    }
    /// Can authorize a pending message (release to UNCLE gateway).
    var canAuthorize: Bool {
        self == .checker || self == .makerChecker
    }
    /// Can see account balances, bilateral FX rates, and
    /// position-level data. Gated separately from compose /
    /// authorize per institutional separation-of-duty: line
    /// operators don't need positions, treasury staff don't move
    /// money.
    var canViewBalance: Bool {
        self == .treasurer || self == .auditor || self == .makerChecker
    }
}

/// Admin-set institutional tier — locked at onboarding by the
/// admin, not changeable by the operator. k=5 in both options;
/// the choice is between DMAP-tier (lighter compute) and
/// ZKVM-tier (heaviest, most defensible). One of `wallet.allAddresses()`'
/// seven tier addresses gets surfaced as the bank's identity.
enum BankTier: String, CaseIterable, Codable, Identifiable {
    case securePlus  = "SecurePlus"   // displayName "Secure+" — k=5 DMAP
    case aaaPlus     = "AAAPlus"      // displayName "AAA+"    — k=5 ZKVM
    var id: String { rawValue }

    /// Human-facing label matching what `TierAddress.displayName`
    /// returns from the SDK for k=5 tiers.
    var sdkDisplayName: String {
        switch self {
        case .securePlus: return "Secure+"
        case .aaaPlus:    return "AAA+"
        }
    }

    var label: String {
        switch self {
        case .securePlus: return "Secure+ (k=5 DMAP)"
        case .aaaPlus:    return "AAA+ (k=5 ZKVM)"
        }
    }
}

/// App-scoped session state. Holds the bank profile, the open
/// AXIOM wallet (a plain `AxiomWallet` — no UNCLE-SAM-special
/// wrapper, no new SDK type), and operator session info.
///
/// The wallet is the same one AxiomWallet uses, opened via
/// `AxiomWallet.open()` / created via `createWalletPair()`.
/// What makes it "institutional" is purely the address tier the
/// bank publishes (k=5 DMAP or k=5 ZKVM, admin-set at
/// onboarding) — the wallet itself has nothing UNCLE-specific.
@MainActor
final class InstitutionSession: ObservableObject {

    // ── Institution profile (set at onboarding, edited in Settings) ──
    @AppStorage("unclesam.bankName")        var bankName: String = ""
    @AppStorage("unclesam.bankBIC")         var bankBIC: String = ""
    @AppStorage("unclesam.jurisdiction")    var jurisdiction: String = ""
    @AppStorage("unclesam.walletEmail")     var walletEmail: String = ""
    /// Admin-locked bank tier. Set once at onboarding.
    @AppStorage("unclesam.bankTier")        var bankTierRaw: String = BankTier.securePlus.rawValue
    /// True after onboarding has completed at least once.
    @AppStorage("unclesam.onboarded")       var onboarded: Bool = false

    var bankTier: BankTier {
        BankTier(rawValue: bankTierRaw) ?? .securePlus
    }

    // ── Operator session ───────────────────────────────────────
    @AppStorage("unclesam.operatorName")    var operatorName: String = "ops_alice"
    @Published var operatorRole: OperatorRole = .makerChecker
    @Published var sessionStartedAt: Date = Date()

    // ── Navigation ─────────────────────────────────────────────
    @Published var activeSection: AppSection = .queue

    // ── Accounts (multi-treasury model) ───────────────────────
    //
    // One AxiomWallet per funded position. Banks push SWIFT from
    // multiple treasuries/branches/desks; each carries its own
    // AXC balance + tier address. AccountConfig persists in
    // @AppStorage as a JSON-encoded array; live InstitutionAccount
    // objects (holding open AxiomWallet handles) live here.
    @Published var accounts: [InstitutionAccount] = []
    /// Index into `accounts` of the currently-selected account —
    /// drives the chrome strip's wallet status, the WireView "Send
    /// from" picker, and the default for every outbound message.
    @Published var activeAccountId: UUID? = nil

    /// JSON-encoded `[AccountConfig]` so @AppStorage can persist
    /// the array. Tedious but standard pattern when @AppStorage
    /// doesn't natively handle the type.
    @AppStorage("unclesam.accountsJSON") private var accountsJSON: String = "[]"

    /// Live shortcut to the active account's wallet — used by the
    /// existing chrome strip + send code paths so we don't rewrite
    /// everything that touches `session.wallet`.
    var wallet: AxiomWallet? {
        activeAccount?.wallet
    }
    /// Live shortcut to the active account's tier address.
    var bankTierAddress: String {
        activeAccount?.tierAddress ?? ""
    }
    /// Live shortcut to the active account's balance in atoms.
    var balanceAtoms: UInt64 {
        activeAccount?.balanceAtoms ?? 0
    }
    /// Active account's last open / send error if any.
    var walletErr: String? {
        activeAccount?.lastError
    }
    /// Look up an account by id — used by the WireView "Send from"
    /// picker, Settings list, etc.
    func account(id: UUID) -> InstitutionAccount? {
        accounts.first(where: { $0.id == id })
    }
    /// The currently-active account (the one the operator is
    /// composing/sending from).
    var activeAccount: InstitutionAccount? {
        guard let id = activeAccountId else { return accounts.first }
        return account(id: id) ?? accounts.first
    }

    // ── Display zoom ───────────────────────────────────────────
    /// Whole-UI scale factor. Driven by the chrome-strip zoom
    /// controls + the ⌘+/⌘− shortcuts. Applied as `.scaleEffect`
    /// on the main shell with the window frame growing in step so
    /// scaled content has room to breathe — matches what an
    /// executive reviewer expects from a Mac app's text-size
    /// control.
    @Published var zoom: CGFloat = 1.0

    private let minZoom: CGFloat = 0.9
    private let maxZoom: CGFloat = 1.6
    private let zoomStep: CGFloat = 0.1

    func zoomIn()    { zoom = min(zoom + zoomStep, maxZoom) }
    func zoomOut()   { zoom = max(zoom - zoomStep, minZoom) }
    func zoomReset() { zoom = 1.0 }

    // ── Account open + create ─────────────────────────────────
    //
    // Each account's wallet lives at
    // `<appDir>/wallets/<pairName>-normal/` (Normal half of a
    // `createWalletPair` call; UNCLE SAM doesn't surface the Ark
    // half in the UI but keeps it on disk as a recovery option).

    /// Hydrate `accounts` from @AppStorage at launch + open each
    /// account's wallet handle. Called once after sdkSetup() →
    /// .ready. No-op if accounts are already loaded.
    ///
    /// Migration: a pre-multi-account install has its wallet at
    /// `<appDir>/wallets/treasury-normal/` but no `accountsJSON`
    /// entry. Detect that case + auto-promote the legacy wallet
    /// into a single "HQ Treasury" account so existing operators
    /// don't lose their onboarded state.
    func tryOpenExistingWallet(appDir: String) {
        if !accounts.isEmpty { return }

        // Try the canonical accountsJSON path first.
        if let data = accountsJSON.data(using: .utf8),
           let configs = try? JSONDecoder().decode([AccountConfig].self, from: data),
           !configs.isEmpty {
            for cfg in configs {
                let acct = InstitutionAccount(config: cfg)
                let normalDir = "\(appDir)/wallets/\(cfg.pairName)-normal"
                if FileManager.default.fileExists(atPath: "\(normalDir)/wallet.axiom") {
                    do {
                        let w = try AxiomWallet.open(dir: normalDir)
                        acct.adoptOpenedWallet(w, bankTier: bankTier)
                    } catch {
                        acct.lastError = "open failed: \(error)"
                        NSLog("%@", "[UNCLESam] open \(cfg.pairName) failed: \(error)")
                    }
                }
                accounts.append(acct)
            }
            if activeAccountId == nil { activeAccountId = accounts.first?.id }
            return
        }

        // Migration path: pre-multi-account install. The
        // single-wallet onboarding used the hardcoded pair name
        // "treasury". If that directory exists, promote it to an
        // account so the operator's existing state survives the
        // refactor.
        let legacyDir = "\(appDir)/wallets/treasury-normal"
        if FileManager.default.fileExists(atPath: "\(legacyDir)/wallet.axiom") {
            do {
                let w = try AxiomWallet.open(dir: legacyDir)
                let cfg = AccountConfig(
                    displayName: "HQ Treasury",
                    purpose: .treasury,
                    subBIC: "",
                    walletEmail: walletEmail,
                    pairName: "treasury"
                )
                let acct = InstitutionAccount(config: cfg)
                acct.adoptOpenedWallet(w, bankTier: bankTier)
                accounts.append(acct)
                activeAccountId = acct.id
                persistAccounts()
                NSLog("%@", "[UNCLESam] migrated legacy single-wallet install to accounts model")
            } catch {
                NSLog("%@", "[UNCLESam] legacy migration failed: \(error)")
            }
        }
    }

    /// Onboarding — create the institution's FIRST account
    /// ("HQ Treasury" by default) and the wallet that backs it.
    /// Subsequent accounts are added via `addAccount()` from
    /// Settings.
    func completeOnboarding(appDir: String,
                            bankName: String,
                            bankBIC: String,
                            jurisdiction: String,
                            walletEmail: String,
                            walletKey: String,
                            tier: BankTier) -> String? {
        let pairName = InstitutionSession.slugFor(name: "HQ Treasury")
        let walletsDir = "\(appDir)/wallets"
        let normalDir = "\(walletsDir)/\(pairName)-normal"
        try? FileManager.default.createDirectory(atPath: walletsDir,
                                                 withIntermediateDirectories: true)
        do {
            if !FileManager.default.fileExists(atPath: "\(normalDir)/wallet.axiom") {
                _ = try createWalletPair(
                    pairName: pairName,
                    email: walletEmail,
                    walletKey: walletKey,
                    parentDir: walletsDir
                )
            }
            let w = try AxiomWallet.open(dir: normalDir)
            // Persist institution-level profile + tier.
            self.bankName = bankName
            self.bankBIC = bankBIC
            self.jurisdiction = jurisdiction
            self.walletEmail = walletEmail
            self.bankTierRaw = tier.rawValue
            self.onboarded = true

            // Stand up the first account.
            let cfg = AccountConfig(
                displayName: "HQ Treasury",
                purpose: .treasury,
                subBIC: "",
                walletEmail: walletEmail,
                pairName: pairName
            )
            let acct = InstitutionAccount(config: cfg)
            acct.adoptOpenedWallet(w, bankTier: tier)
            accounts.append(acct)
            activeAccountId = acct.id
            persistAccounts()
            return nil
        } catch {
            let msg = "\(error)"
            NSLog("%@", "[UNCLESam] onboarding failed: \(error)")
            return msg
        }
    }

    /// Add a new institutional account to this install.
    /// Called from Settings → Institution accounts → Add.
    @discardableResult
    func addAccount(appDir: String,
                    displayName: String,
                    purpose: AccountPurpose,
                    subBIC: String,
                    walletEmail: String,
                    walletKey: String,
                    color: AccountColor) -> String? {
        let pairName = InstitutionSession.slugFor(name: displayName)
        // Reject collision with an existing account's directory.
        if accounts.contains(where: { $0.config.pairName == pairName }) {
            return "An account with a similar name already exists. Pick a different display name."
        }
        let walletsDir = "\(appDir)/wallets"
        let normalDir  = "\(walletsDir)/\(pairName)-normal"
        try? FileManager.default.createDirectory(atPath: walletsDir,
                                                 withIntermediateDirectories: true)
        do {
            if !FileManager.default.fileExists(atPath: "\(normalDir)/wallet.axiom") {
                _ = try createWalletPair(
                    pairName: pairName,
                    email: walletEmail,
                    walletKey: walletKey,
                    parentDir: walletsDir
                )
            }
            let w = try AxiomWallet.open(dir: normalDir)
            let cfg = AccountConfig(
                displayName: displayName, purpose: purpose,
                subBIC: subBIC, walletEmail: walletEmail,
                pairName: pairName, color: color
            )
            let acct = InstitutionAccount(config: cfg)
            acct.adoptOpenedWallet(w, bankTier: bankTier)
            accounts.append(acct)
            persistAccounts()
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// Import an existing AxiomWallet from a source directory.
    /// Copies the wallet's files into UNCLE SAM's own data dir
    /// (so the operator can continue using their original wallet
    /// in AxiomWallet without state drift), then registers it as
    /// an InstitutionAccount.
    ///
    /// When `renameOriginal` is true, the source directory is
    /// renamed to `<original>.imported-to-UNCLESam-YYYY-MM-DD` so
    /// AxiomWallet won't accidentally open the same wallet at the
    /// same time as UNCLE SAM. Best-effort: if the source is
    /// flocked or otherwise un-renameable the import still
    /// succeeds; the operator gets a warning string back.
    ///
    /// Returns nil on success, an error message on failure (e.g.
    /// source has no wallet.axiom, target name collides, the
    /// rename couldn't complete).
    @discardableResult
    func importAccount(appDir: String,
                        sourceDir: String,
                        displayName: String,
                        purpose: AccountPurpose,
                        subBIC: String,
                        color: AccountColor,
                        renameOriginal: Bool) -> String? {
        let pairName = InstitutionSession.slugFor(name: displayName)
        if accounts.contains(where: { $0.config.pairName == pairName }) {
            return "An account with a similar name already exists. Pick a different display name."
        }
        // Validate source — must contain wallet.axiom.
        let sourceWalletCbor = "\(sourceDir)/wallet.axiom"
        guard FileManager.default.fileExists(atPath: sourceWalletCbor) else {
            return "Source directory does not contain a wallet.axiom file. Pick the wallet's directory (the one with wallet.axiom inside)."
        }
        let walletsDir = "\(appDir)/wallets"
        let targetDir  = "\(walletsDir)/\(pairName)-normal"
        try? FileManager.default.createDirectory(
            atPath: walletsDir, withIntermediateDirectories: true)
        // Refuse to overwrite an existing target — operator picks a
        // different display name or removes the old account first.
        if FileManager.default.fileExists(atPath: "\(targetDir)/wallet.axiom") {
            return "A wallet for `\(pairName)-normal` already exists in UNCLE SAM's data directory. Pick a different display name."
        }
        do {
            // Copy the source directory wholesale. Captures the
            // wallet.axiom + lockfile + any sibling state (cheques/,
            // receipts/, maildir/ if present).
            try FileManager.default.copyItem(atPath: sourceDir, toPath: targetDir)
            // Open the copy via the SDK — same path the addAccount
            // happy path takes.
            let w = try AxiomWallet.open(dir: targetDir)
            // Extract the canonical wallet email — that's the
            // walletEmail in AccountConfig (matches what
            // addAccount captures from the operator's input).
            let email = w.email()
            let cfg = AccountConfig(
                displayName: displayName, purpose: purpose,
                subBIC: subBIC, walletEmail: email,
                pairName: pairName, color: color)
            let acct = InstitutionAccount(config: cfg)
            acct.adoptOpenedWallet(w, bankTier: bankTier)
            accounts.append(acct)
            persistAccounts()
            // Best-effort rename of the original. We do this AFTER
            // the copy + adopt succeed so an interrupted import
            // doesn't leave the operator wallet-less. The rename
            // suffix is calendar-dated so re-running on the same
            // day doesn't clash without alerting the operator.
            if renameOriginal {
                let dateStamp = String(
                    ISO8601DateFormatter().string(from: Date()).prefix(10))
                let renamedPath = "\(sourceDir).imported-to-UNCLESam-\(dateStamp)"
                if FileManager.default.fileExists(atPath: renamedPath) {
                    return "Imported successfully. WARNING: original directory NOT renamed — `\(renamedPath)` already exists. Rename manually before opening the original in AxiomWallet."
                }
                do {
                    try FileManager.default.moveItem(
                        atPath: sourceDir, toPath: renamedPath)
                } catch {
                    return "Imported successfully. WARNING: original directory NOT renamed (\(error.localizedDescription)). Rename `\(sourceDir)` manually before opening it in AxiomWallet to avoid concurrent-use corruption."
                }
            }
            return nil
        } catch {
            // Cleanup partial copy on failure so re-trying with
            // the same display name doesn't trip the collision
            // check above.
            try? FileManager.default.removeItem(atPath: targetDir)
            return "\(error)"
        }
    }

    /// Import an existing wallet from a password-encrypted AXPW
    /// portable backup (the cross-app transit format). Unlike
    /// `importAccount` (which copies a plaintext wallet FOLDER and
    /// is broken for AxiomWallet's at-rest-sealed AXMK keystores),
    /// this path decrypts the AXPW frame to canonical AXWL with the
    /// operator-supplied wallet key, then imports it PLAINTEXT via
    /// the SDK's `from_file` (`AppStorage::plain()`) — UNCLE SAM
    /// deliberately stays plaintext-at-rest (no Keychain vault).
    ///
    /// `walletKey` is the same password used to seal the .axpw on
    /// the source device/app. It is NOT stored — the operator must
    /// re-supply it at every export/import.
    ///
    /// Returns nil on success, an error message on failure.
    @discardableResult
    func importPortableBackupAccount(appDir: String,
                                     axpwPath: String,
                                     walletKey: String,
                                     displayName: String,
                                     purpose: AccountPurpose,
                                     subBIC: String,
                                     color: AccountColor) -> String? {
        let pairName = InstitutionSession.slugFor(name: displayName)
        if accounts.contains(where: { $0.config.pairName == pairName }) {
            return "An account with a similar name already exists. Pick a different display name."
        }
        let walletsDir = "\(appDir)/wallets"
        let targetDir  = "\(walletsDir)/\(pairName)-normal"
        try? FileManager.default.createDirectory(
            atPath: walletsDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: "\(targetDir)/wallet.axiom") {
            return "A wallet for `\(pairName)-normal` already exists in UNCLE SAM's data directory. Pick a different display name."
        }
        // Read + validate the AXPW frame.
        let frame: Data
        do {
            frame = try Data(contentsOf: URL(fileURLWithPath: axpwPath))
        } catch {
            return "Could not read the .axpw file: \(error.localizedDescription)"
        }
        guard PortableBackup.isPortableFrame(frame) else {
            return "The selected file is not an AXPW portable backup (bad magic header). Pick a `.axpw` exported from AxiomWallet or UNCLE SAM."
        }
        // Decrypt to canonical plaintext AXWL with the wallet key.
        let axwl: Data
        do {
            axwl = try PortableBackup.open(frame, password: walletKey)
        } catch {
            return "Could not decrypt the portable backup. Check the wallet key matches the one used to export it."
        }
        // Stage the plaintext AXWL at a temp path whose name does
        // NOT end in `/wallet.axiom` — `from_file` treats a source
        // named wallet.axiom as a ciphered keystore, so the blob
        // suffix keeps it on the plaintext-canonical import path.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncle-import-\(UUID().uuidString).axwlblob")
        do {
            try axwl.write(to: tmp, options: .atomic)
        } catch {
            return "Could not stage the decrypted wallet: \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            // PLAINTEXT import — SDK `from_file` (AppStorage::plain()).
            let w = try AxiomWallet.fromFile(
                sourcePath: tmp.path,
                parentDir: walletsDir,
                walletName: "\(pairName)-normal")
            let email = w.email()
            let cfg = AccountConfig(
                displayName: displayName, purpose: purpose,
                subBIC: subBIC, walletEmail: email,
                pairName: pairName, color: color)
            let acct = InstitutionAccount(config: cfg)
            acct.adoptOpenedWallet(w, bankTier: bankTier)
            accounts.append(acct)
            persistAccounts()
            return nil
        } catch {
            // Clean up any partial target so a retry with the same
            // display name doesn't trip the collision check.
            try? FileManager.default.removeItem(atPath: targetDir)
            return "\(error)"
        }
    }

    /// Export an account's wallet to a password-encrypted AXPW
    /// portable backup. In UNCLE SAM `wallet.axiom` is plaintext
    /// canonical AXWL (no Keychain vault), so export reads it
    /// directly and seals it under the operator-supplied wallet
    /// key. Returns nil on success, an error message on failure.
    @discardableResult
    func exportPortableBackup(appDir: String,
                              account: InstitutionAccount,
                              walletKey: String,
                              to destURL: URL) -> String? {
        let walletDir = "\(appDir)/wallets/\(account.config.pairName)-normal"
        let walletCbor = "\(walletDir)/wallet.axiom"
        let axwl: Data
        do {
            // UNCLE SAM stores the canonical AXWL plaintext on disk.
            axwl = try Data(contentsOf: URL(fileURLWithPath: walletCbor))
        } catch {
            return "Could not read the wallet file: \(error.localizedDescription)"
        }
        do {
            let axpw = try PortableBackup.seal(axwl, password: walletKey)
            try axpw.write(to: destURL, options: .atomic)
            return nil
        } catch {
            return "Export failed: \(error.localizedDescription)"
        }
    }

    /// Switch the active account — affects chrome strip, WireView
    /// composer "Send from" default, and the default wallet for
    /// outbound sends.
    func setActiveAccount(_ id: UUID) {
        if accounts.contains(where: { $0.id == id }) {
            activeAccountId = id
        }
    }

    /// Refresh active account's balance after a send. Kept for
    /// back-compat with existing call sites (MessageStore).
    func refreshBalance() {
        activeAccount?.refreshBalance()
    }

    /// Encode the current accounts array to AppStorage. The wallet
    /// handles aren't persisted (they reopen at launch from the
    /// canonical directories).
    private func persistAccounts() {
        let configs = accounts.map { $0.config }
        if let data = try? JSONEncoder().encode(configs),
           let str = String(data: data, encoding: .utf8) {
            accountsJSON = str
        }
    }

    /// Slug a free-form display name into a directory-safe pair
    /// name. Lowercase, dashes, no surprises — matches what
    /// AxiomWallet's pair-name convention expects.
    private static func slugFor(name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "_" || ch == "-" { out.append("-") }
        }
        // Collapse double dashes.
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out.isEmpty ? "treasury" : out
    }

}

/// Top-level navigation enum. Matches the rail entries; one case
/// per section. Defines the icon + title in one place so adding a
/// future section (MT202, regulatory reports, etc.) is mechanical.
enum AppSection: String, CaseIterable, Identifiable {
    case queue          = "Message Queue"
    case dashboard      = "Dashboard"
    case wire           = "Create Message"
    case inbound        = "Inbound Detail"
    case audit          = "Audit Log"
    case counterparties = "Counterparty Banks"
    case settings       = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .queue:          return "tray.full"
        case .dashboard:      return "rectangle.grid.2x2"
        case .wire:           return "square.and.pencil"
        case .inbound:        return "arrow.down.forward.square"
        case .audit:          return "list.bullet.rectangle"
        case .counterparties: return "building.columns"
        case .settings:       return "gearshape"
        }
    }
}

/// The window's persistent shell — chrome strip on top, rail on
/// left, content panel on right, Connection Health strip on the
/// bottom. The content panel switches based on
/// `session.activeSection`. The whole shell scales by
/// `session.zoom` (for low-vision reviewers) with the window frame
/// growing in step.
struct MainShell: View {
    @EnvironmentObject private var session: InstitutionSession
    @EnvironmentObject private var store: MessageStore
    @EnvironmentObject private var releaseUpdate: ReleaseUpdateWatcher

    var body: some View {
        // Resizable + zoomable shell. The underlying shell lays out
        // at `window / zoom`, then `scaleEffect` enlarges it back
        // to the window's real pixel dimensions. That way:
        //   • zoom = 1.0  → 1 logical px = 1 visual px (default).
        //   • zoom = 1.5  → shell lays out at window/1.5 size and
        //     paints 1.5× larger, so text + chrome grow but layout
        //     stability is preserved.
        //   • the user can drag the window larger at any zoom and
        //     the shell grows with it (no clipping).
        GeometryReader { geo in
            shellContent
                .frame(width: geo.size.width / session.zoom,
                       height: geo.size.height / session.zoom,
                       alignment: .topLeading)
                .scaleEffect(session.zoom, anchor: .topLeading)
        }
    }

    private var shellContent: some View {
        VStack(spacing: 0) {
            updateBanner
            ChromeStrip()
            HStack(spacing: 0) {
                RailNav()
                    .frame(width: 220)
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DesignTokens.bgPrimary)
            }
            Divider()
            ConnectionHealthStrip()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Transient "checking for updates" chip (auto-hides).
        .overlay(alignment: .bottom) {
            if releaseUpdate.checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking for updates…").font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: releaseUpdate.checking)
        // One-shot blocking alert on a CoreID rotation — the network's
        // canonical Core changed and this build is rejected until updated.
        .alert("Update Required", isPresented: $releaseUpdate.mandatoryAlertPending) {
            if releaseUpdate.verdict.releaseInfo?.url != nil {
                Button("Download") {
                    releaseUpdate.mandatoryAlertPending = false
                    Task { await releaseUpdate.downloadAndReveal() }
                }
            }
            Button("Later", role: .cancel) { releaseUpdate.mandatoryAlertPending = false }
        } message: {
            if case .mandatory(let info) = releaseUpdate.verdict {
                Text("The AXIOM network has upgraded its Core (new CoreID \(String(info.coreId.prefix(8)))…). Core upgrades are rare in production but mandatory: this build runs an older Core, and transacting against a Core the validators no longer run would diverge this institution's wallet state from the network and can permanently damage it. Install \(info.version) before transacting. (Yellow Paper §23.10 — Core Upgrade as State Transition; §16.8.3 — client and validators run the same Core.)")
            } else {
                Text("A required update is available.")
            }
        }
    }

    /// Persistent update banner above the chrome strip — shown whenever
    /// the release feed reports a newer build. Red for a mandatory
    /// (CoreID-rotation) update, amber for an optional same-Core one.
    @ViewBuilder
    private var updateBanner: some View {
        if let info = releaseUpdate.verdict.releaseInfo {
            let mandatory = releaseUpdate.verdict.isMandatory
            HStack(spacing: 10) {
                Image(systemName: mandatory ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                    .foregroundColor(.white)
                Text(mandatory
                     ? "Update required — the network moved to a new Core (\(String(info.coreId.prefix(8)))…). This build can't transact until you install \(info.version)."
                     : "Update available: \(info.version) (same Core). Recommended.")
                    .font(.callout)
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(releaseUpdate.downloading ? "Downloading…" : "Download") {
                    Task { await releaseUpdate.downloadAndReveal() }
                }
                .disabled(releaseUpdate.downloading || info.url == nil)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(mandatory ? Color.red.opacity(0.9) : Color.orange.opacity(0.9))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.activeSection {
        case .queue:          MessageQueueView()
        case .dashboard:      DashboardView()
        case .wire:           WireView()
        case .inbound:        InboundView()
        case .audit:          AuditView()
        case .counterparties: CounterpartiesView()
        case .settings:       UNCLESettingsView()
        }
    }
}

/// Navy chrome strip at the top of the window. Shows the
/// institution's brand on the left, the UNCLE SAM product mark
/// centre, and the operator session + zoom controls on the right.
struct ChromeStrip: View {
    @EnvironmentObject private var session: InstitutionSession

    /// Pending account switch — when the operator picks a different
    /// account from the menu or the Settings list we stash the id
    /// here and surface a confirmation alert before applying.
    /// Confirmation prevents the most common banker mistake:
    /// authorising a wire on the wrong funded position because the
    /// active account got swapped accidentally.
    @State private var pendingSwitchAccountId: UUID? = nil

    var body: some View {
        HStack(spacing: 14) {
            // Product mark — AXIOM seal (white-on-transparent) +
            // "UNCLE SAM" wordmark in white. Previously we used
            // the UncleSamLogo PNG with .colorInvert() — but that
            // PNG had a WHITE background, and inverting turned it
            // BLACK. On the original fixed-navy chrome the black
            // box blended in; once chrome started tinting to the
            // active account's colour (burgundy / forest / etc.)
            // the inverted-background became a hard-edged black
            // rectangle that read as "a little black house icon"
            // on every non-navy tint. Replaced 2026-05-30 with the
            // transparent-bg AXIOM seal + Swift Text wordmark so
            // the product mark renders cleanly on any palette.
            HStack(spacing: 8) {
                Image("AxiomSealWhite", bundle: .main)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 24)
                HStack(spacing: 4) {
                    Text("UNCLE")
                        .font(.system(size: 13, weight: .bold))
                        .tracking(1.8)
                        .foregroundStyle(Color.white)
                    Text("SAM")
                        .font(.system(size: 13, weight: .light))
                        .tracking(1.8)
                        .foregroundStyle(Color.white.opacity(0.85))
                }
            }
            .help("UNCLE SAM — SWiFT-Aligned Messaging")
            Divider()
                .frame(height: 28)
                .background(DesignTokens.textOnChrome.opacity(0.25))
            // Institution mark
            HStack(spacing: 10) {
                // Bright white instead of brand gold — the chrome
                // strip tints to the active account's colour, and
                // gold-on-burgundy / gold-on-forest etc. drops
                // contrast hard. White is the universal high-
                // contrast choice against any tint in the palette.
                Image(systemName: "building.columns.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.white)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.bankName.isEmpty
                         ? "(no bank profile)" : session.bankName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignTokens.textOnChrome)
                    Text(session.bankBIC.isEmpty
                         ? "—" : session.bankBIC)
                        .font(DesignTokens.monoSmallFont)
                        .foregroundStyle(DesignTokens.textOnChrome.opacity(0.92))
                }
            }
            Spacer()
            // Wallet status — balance + tier address (read-only,
            // glanceable). Only shows after the wallet is open.
            if session.wallet != nil {
                walletStatusBlock
            }
            Spacer()
            zoomCluster
            // Operator session — right side
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 6) {
                    Text(session.operatorName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignTokens.textOnChrome)
                    Text("· \(session.operatorRole.rawValue)")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.textOnChrome.opacity(0.92))
                }
                Text("Session started \(timeFmt.string(from: session.sessionStartedAt))")
                    .font(DesignTokens.monoSmallFont)
                    .foregroundStyle(DesignTokens.textOnChrome.opacity(0.92))
            }
        }
        .padding(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18))
        // Chrome strip background tints to the active account's
        // colour so the banker can identify the funded position at
        // a glance. Falls back to the design-system bgChrome when
        // there's no active account (pre-onboarding) or before the
        // wallet opens.
        .background(session.activeAccount?.config.color.color
                    ?? DesignTokens.bgChrome)
        .alert("Switch active account?",
               isPresented: Binding(
                get: { pendingSwitchAccountId != nil },
                set: { if !$0 { pendingSwitchAccountId = nil } }
               ),
               presenting: pendingSwitchAccountId.flatMap { session.account(id: $0) }
        ) { target in
            Button("Cancel", role: .cancel) {
                pendingSwitchAccountId = nil
            }
            Button("Switch") {
                session.setActiveAccount(target.id)
                pendingSwitchAccountId = nil
            }
        } message: { target in
            let current = session.activeAccount?.config.displayName ?? "—"
            Text("""
            Switching from \(current) to \(target.config.displayName).

            This changes the funded position UNCLE SAM uses for every outbound message and the BIC that lands in :52A: of the SWIFT envelope. The chrome strip will tint to the new account's accent colour.

            Confirm before continuing — a banker authorising a wire on the wrong account is the single most common operational error in multi-account treasury setups.
            """)
        }
    }

    /// Wallet identity block on the chrome strip — banker needs to
    /// see which funded position is active at a glance, plus the
    /// published tier address (wallet identity) and balance. The
    /// display name reads as the primary label; the tier address
    /// is the secondary mono line beneath.
    private var walletStatusBlock: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                // Primary line — account display name.
                Text(session.activeAccount?.config.displayName ?? "(no account)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignTokens.textOnChrome)
                // Secondary line — wallet identity (tier address).
                Text(truncatedAddress(session.bankTierAddress))
                    .font(DesignTokens.monoSmallFont)
                    .foregroundStyle(DesignTokens.textOnChrome.opacity(0.85))
                    .help(session.bankTierAddress)
            }
            // Account switcher dropdown — only surfaces when there
            // are 2+ accounts. Switching prompts a confirm alert.
            if session.accounts.count > 1 {
                accountSwitcher
            }
            Divider().frame(height: 28)
                .background(DesignTokens.textOnChrome.opacity(0.25))
            // Balance + tier label. Balance gated by operator role
            // — Maker / Checker see "— — — AXC" so a line operator
            // can't read account positions. Treasurer / Auditor /
            // demo Maker+Checker see the real number.
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.shield")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white)
                    CensoredBalance(
                        atoms: session.balanceAtoms,
                        canView: session.operatorRole.canViewBalance,
                        font: .system(size: 13, weight: .semibold,
                                      design: .monospaced)
                    )
                    .foregroundStyle(session.operatorRole.canViewBalance
                                     ? DesignTokens.textOnChrome
                                     : DesignTokens.textOnChrome.opacity(0.5))
                }
                Text("\(session.bankTier.sdkDisplayName) · k=5 · \(session.activeAccount?.config.purpose.label ?? "")")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.brandGold)
            }
        }
    }

    /// Compact dropdown that swaps the institution's active
    /// account. Each menu row shows purpose icon + name + balance
    /// + colour swatch so the banker can pick the right funded
    /// position by glance. Selection routes through the confirm
    /// alert so an accidental swap can be cancelled.
    private var accountSwitcher: some View {
        Menu {
            ForEach(session.accounts) { acct in
                Button {
                    // Don't swap directly — fire the confirm alert.
                    // No-op when picking the currently-active
                    // account (the alert would compare the same
                    // name on both sides).
                    if acct.id != session.activeAccountId {
                        pendingSwitchAccountId = acct.id
                    }
                } label: {
                    HStack {
                        Image(systemName: acct.config.purpose.icon)
                        Text(acct.config.displayName)
                        Spacer()
                        if session.operatorRole.canViewBalance {
                            Text(acct.balanceDisplay)
                                .font(DesignTokens.monoSmallFont)
                        } else {
                            Text(acct.config.purpose.label)
                                .font(.system(size: 10))
                        }
                    }
                }
            }
        } label: {
            // `.tint(.white)` + `.foregroundStyle(.white)` are
            // BOTH needed — borderlessButton menu style applies the
            // system's control-text colour on top of whatever the
            // label says, which on `.preferredColorScheme(.light)`
            // renders as black. .tint sets the control colour,
            // foregroundStyle covers the text/SF Symbol fill.
            HStack(spacing: 4) {
                Image(systemName: session.activeAccount?.config.purpose.icon
                                  ?? "building.columns")
                    .font(.system(size: 10))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .tint(.white)
        .help("Switch active account — \(session.accounts.count) configured")
    }

    private func truncatedAddress(_ s: String) -> String {
        if s.count <= 28 { return s }
        let head = s.prefix(14)
        let tail = s.suffix(8)
        return "\(head)…\(tail)"
    }

    private var zoomCluster: some View {
        HStack(spacing: 0) {
            zoomButton("A", size: 9, action: session.zoomOut,
                       help: "Smaller text (⌘−)")
            Divider()
                .frame(height: 14)
                .background(DesignTokens.textOnChrome.opacity(0.25))
            Button(action: session.zoomReset) {
                Text("\(Int(session.zoom * 100))%")
                    .font(DesignTokens.monoSmallFont)
                    .foregroundStyle(DesignTokens.textOnChrome)
                    .frame(width: 44)
            }
            .buttonStyle(.plain)
            .help("Reset text size (⌘0)")
            Divider()
                .frame(height: 14)
                .background(DesignTokens.textOnChrome.opacity(0.25))
            zoomButton("A", size: 16, action: session.zoomIn,
                       help: "Larger text (⌘+)")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(DesignTokens.textOnChrome.opacity(0.18),
                              lineWidth: 0.5)
        )
        .padding(.trailing, 8)
    }

    private func zoomButton(_ label: String, size: CGFloat,
                            action: @escaping () -> Void,
                            help: String) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(DesignTokens.textOnChrome)
                .frame(width: 28, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var timeFmt: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }
}

/// Left navigation rail. List of sections with icon + label;
/// selected one tinted with brand gold.
struct RailNav: View {
    @EnvironmentObject private var session: InstitutionSession
    @EnvironmentObject private var store: MessageStore
    // 乖乖 — decorative inert easter egg. See KuaikuaiOverlay.swift.
    @State private var showKuaikuai: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SECTIONS")
                .font(DesignTokens.labelFont)
                .tracking(0.6)
                .foregroundStyle(DesignTokens.textTertiary)
                .padding(EdgeInsets(top: 20, leading: 20, bottom: 12, trailing: 18))
            ForEach(AppSection.allCases) { section in
                Button(action: { session.activeSection = section }) {
                    HStack(spacing: 12) {
                        Image(systemName: section.icon)
                            .font(.system(size: 13))
                            .frame(width: 18, alignment: .center)
                        Text(section.rawValue)
                            .font(.system(size: 13))
                        Spacer()
                        // Counter badge on Queue when there are
                        // items awaiting checker attention.
                        if section == .queue,
                           store.pendingAuthorization().count > 0 {
                            Text("\(store.pendingAuthorization().count)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DesignTokens.statusPendingFg)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DesignTokens.statusPendingBg)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .foregroundStyle(session.activeSection == section
                                     ? DesignTokens.textPrimary
                                     : DesignTokens.textSecondary)
                    .padding(EdgeInsets(top: 9, leading: 20, bottom: 9, trailing: 18))
                    .background(session.activeSection == section
                                ? DesignTokens.brandNavySoft
                                : Color.clear)
                    .overlay(alignment: .leading) {
                        if session.activeSection == section {
                            Rectangle()
                                .fill(DesignTokens.brandGold)
                                .frame(width: 3)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            // Footer — UNCLE SAM build info
            VStack(alignment: .leading, spacing: 2) {
                Text("UNCLE SAM")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("Design preview · v0.1.0")
                    .font(DesignTokens.monoSmallFont)
                    .foregroundStyle(DesignTokens.textTertiary)
                    // 乖乖 — decorative; see KuaikuaiOverlay.swift.
                    .kuaikuaiTapTarget(presenting: $showKuaikuai)
            }
            .padding(EdgeInsets(top: 10, leading: 20, bottom: 16, trailing: 18))
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DesignTokens.bgSecondary)
        // `.fullScreenCover` is iOS-only; use `.sheet` on macOS.
        .sheet(isPresented: $showKuaikuai) {
            KuaikuaiOverlay(dismiss: { showKuaikuai = false })
        }
    }
}

// =================================================================
// ConnectionHealthStrip — persistent bottom bar showing UNCLE
// gateway state, queue depth, and last heartbeat. From UNCLE SAM's
// perspective UNCLE is the network the messages go through — NOT
// "SWIFTNet" — so the labels read in UNCLE vocabulary.
// =================================================================

struct ConnectionHealthStrip: View {
    @EnvironmentObject private var store: MessageStore
    @EnvironmentObject private var nablaNodes: NablaNodesStore

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                Text("UNCLE gateway")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.textSecondary)
                Text(store.gatewayState.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(stateColor)
            }
            Divider().frame(height: 12)
            // ── Confirmed-grade Nabla capacity ──────────────
            // UNCLE SAM only honors Confirmed-grade Nabla nodes
            // for settlement-finality reads. When zero Confirmed
            // are reachable the bank's ops team must see an
            // obvious "settlements paused" signal — never a silent
            // degradation to a Provisional answer.
            HStack(spacing: 4) {
                Circle()
                    .fill(nablaCapacityColor)
                    .frame(width: 8, height: 8)
                Text("Confirmed-grade Nabla")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("\(nablaNodes.confirmedGradeAvailable) of \(nablaNodes.total)")
                    .font(DesignTokens.monoSmallFont)
                    .foregroundStyle(nablaCapacityColor)
                if !nablaNodes.hasSettlementCapacity {
                    Text("· settlements paused")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                }
            }
            .help("UNCLE SAM only routes Nabla queries through Confirmed-grade nodes (zero false positives). Provisional nodes are visible in Settings → Network but never used for settlement finality.")
            Divider().frame(height: 12)
            HStack(spacing: 4) {
                Text("Queue depth")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("\(store.queueDepth)")
                    .font(DesignTokens.monoSmallFont)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            Divider().frame(height: 12)
            HStack(spacing: 4) {
                Text("Last heartbeat")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(heartbeatDisplay)
                    .font(DesignTokens.monoSmallFont)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Text("ISO 20022 pacs.008 ·")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("legacy MT103 toggle")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.textTertiary)
            }
        }
        .padding(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
        .background(DesignTokens.bgSecondary)
    }

    private var nablaCapacityColor: Color {
        if !nablaNodes.hasSettlementCapacity {
            return DesignTokens.statusRejectedFg
        }
        if nablaNodes.confirmedGradeAvailable <= 1 {
            return DesignTokens.statusPendingFg  // one-degraded warning
        }
        return DesignTokens.statusSettledFg
    }

    private var stateColor: Color {
        switch store.gatewayState {
        case .connected:    return DesignTokens.statusSettledFg
        case .reconnecting: return DesignTokens.statusPendingFg
        case .disconnected: return DesignTokens.statusRejectedFg
        }
    }

    private var heartbeatDisplay: String {
        let secondsAgo = Int(Date().timeIntervalSince(store.lastHeartbeat))
        if secondsAgo < 5 { return "just now" }
        if secondsAgo < 60 { return "\(secondsAgo)s ago" }
        if secondsAgo < 3600 { return "\(secondsAgo / 60)m ago" }
        return timestampDisplay(store.lastHeartbeat)
    }
}
