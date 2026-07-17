import SwiftUI
import AppKit

// =================================================================
// SettingsView — account list + per-account editor.
//
// v0 UI: simple master/detail. Add / remove accounts. Each account
// has fields for label, wallet dir, wallet email, SMTP host:port,
// POP3 host:port, poll interval, plus TLS + auth on .email kind.
//
// Two add-account flows live behind the one "+" button:
//
//   plain click       → adds a `.email` account (real mail provider
//                       over TLS, the modal user-facing path).
//   Option-click + pw → adds a `.axiomDev` account (FATMAMA / dev
//                       env). Hidden because random users shouldn't
//                       see the dev path; gated by the per-event
//                       passcode so a shoulder-surfed Option-click
//                       still doesn't reveal it.
//
// Edits are draft-local. Save commits to disk + restarts the
// worker; Revert discards. No auto-save — typos in a host or port
// would otherwise restart the worker on every keystroke.
// =================================================================

/// The shared passcode that unlocks the dev / FATMAMA add-account
/// flow. Distributed out-of-band to people who need it. Per-event
/// (not remembered between clicks) so a single leak doesn't unlock
/// every future Option-click.
private let kFatmamaPasscode = "fatmama approve axiom"

struct SettingsView: View {
    @ObservedObject var store: AccountStore
    @ObservedObject var workers: WorkerRegistry
    @State private var selectedId: UUID?
    @State private var showPasscodeSheet: Bool = false
    // 乖乖 — decorative inert easter egg. See KuaikuaiOverlay.swift.
    @State private var showKuaikuai: Bool = false
    // Dev-account clean-up (Kiddo ↔ FATMAMA resync — see
    // `cleanUpDevAccounts()`). `isCleaningDev` disables the button
    // for the duration; `cleanupStatus` is a transient footer line.
    @State private var showCleanupConfirm: Bool = false
    @State private var isCleaningDev: Bool = false
    @State private var cleanupStatus: String = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 460)
        // `.fullScreenCover` is iOS-only; use `.sheet` on macOS.
        .sheet(isPresented: $showKuaikuai) {
            KuaikuaiOverlay(dismiss: { showKuaikuai = false })
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(store.accounts, selection: $selectedId) { acct in
                accountRow(acct)
                    .tag(acct.id)
            }
            HStack {
                Button(action: addAccount) {
                    Image(systemName: "plus")
                        .frame(minWidth: KiddoTokens.Size.minHit,
                               minHeight: KiddoTokens.Size.minHit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add account")
                .help("Add account")
                Button(action: removeSelected) {
                    Image(systemName: "minus")
                        .frame(minWidth: KiddoTokens.Size.minHit,
                               minHeight: KiddoTokens.Size.minHit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(selectedId == nil)
                .accessibilityLabel("Remove account")
                .help("Remove account")
                Spacer()
            }
            .padding(KiddoTokens.Spacing.xs)
            .background(.thinMaterial)
            // Dev-only, deliberately serious: a red, labeled,
            // destructive control in its OWN row — never mixed in with
            // the casual +/− icons. Shown only when dev accounts exist,
            // so a normal .email user never sees it (same visibility
            // discipline as the Option-click dev add-account flow). The
            // confirming `.alert` is attached to the always-present
            // container below, NOT to this conditional button — a
            // presentation modifier on a view that comes and goes
            // silently no-ops, which is why the first version "did
            // nothing".
            if hasDevAccounts {
                Button(role: .destructive, action: { showCleanupConfirm = true }) {
                    HStack(spacing: KiddoTokens.Spacing.xxs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(isCleaningDev ? "Cleaning up…" : "Clean up dev accounts…")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .tint(.red)
                .foregroundStyle(.red)
                .disabled(isCleaningDev)
                .accessibilityLabel("Clean up dev accounts")
                .help("Delete every @axiom.internal account from Kiddo and "
                    + "FATMAMA, then recreate them from the wallets on disk")
                .padding(EdgeInsets(top: KiddoTokens.Spacing.xxs,
                                    leading: KiddoTokens.Spacing.xs,
                                    bottom: KiddoTokens.Spacing.xxs,
                                    trailing: KiddoTokens.Spacing.xs))
            }
            if !cleanupStatus.isEmpty {
                Text(cleanupStatus)
                    .font(KiddoTokens.Typography.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(EdgeInsets(top: KiddoTokens.Spacing.xxs,
                                        leading: KiddoTokens.Spacing.xs,
                                        bottom: 0,
                                        trailing: KiddoTokens.Spacing.xs))
            }
            // 乖乖 — tiny build label that exists primarily as the
            // tap target. Decorative; click 7× to summon.
            HStack {
                Text("AXIOM Kiddo · v0.1")
                    .font(KiddoTokens.Typography.micro)
                    .foregroundStyle(.tertiary)
                    .kuaikuaiTapTarget(presenting: $showKuaikuai)
                Spacer()
            }
            .padding(EdgeInsets(top: 0, leading: KiddoTokens.Spacing.xs,
                                bottom: KiddoTokens.Spacing.xxs,
                                trailing: KiddoTokens.Spacing.xs))
        }
        .frame(minWidth: 220)
        // Confirmation for the destructive clean-up. Attached HERE, on
        // the always-present sidebar container, so it presents reliably
        // regardless of the conditional button's presence.
        .alert("Clean up dev accounts?", isPresented: $showCleanupConfirm) {
            Button("Clean Up", role: .destructive) { cleanUpDevAccounts() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes all \(devAccounts.count) @axiom.internal "
                + "account(s) from Kiddo and FATMAMA, then recreates one "
                + "per dev wallet on disk and re-registers each. Only dev "
                + "accounts are touched — real email accounts are left alone.")
        }
        .sheet(isPresented: $showPasscodeSheet) {
            PasscodeGateSheet { entered in
                showPasscodeSheet = false
                // Silent on wrong passcode — no toast, no shake, no
                // hint that something exists behind this gate.
                // Re-Option-clicking "+" prompts again.
                if entered == kFatmamaPasscode {
                    addDevAccount()
                }
            }
        }
    }


    private func accountRow(_ acct: KiddoAccount) -> some View {
        let style = workerStatusStyle(workers.worker(for: acct.id))
        return HStack(spacing: KiddoTokens.Spacing.xxs) {
            Circle()
                .fill(style.fg)
                .frame(width: KiddoTokens.Size.statusDot,
                       height: KiddoTokens.Size.statusDot)
                .accessibilityLabel(style.label)
                .help(style.label)
            // Status is never color-only — the style's SF Symbol
            // rides next to the dot in the list row.
            Image(systemName: style.symbol)
                .font(KiddoTokens.Typography.caption)
                .foregroundStyle(style.fg)
                .accessibilityHidden(true)
                .help(style.label)
            VStack(alignment: .leading, spacing: 1) {
                Text(acct.label).font(KiddoTokens.Typography.body)
                Text(acct.walletEmail.isEmpty ? "no mailbox" : acct.walletEmail)
                    .font(KiddoTokens.Typography.monoSmall)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Same conditions the old `statusColor` used, mapped onto the
    /// one canonical status style: no worker / not running → idle,
    /// lastError → attention, otherwise running.
    private func workerStatusStyle(_ worker: AccountWorker?) -> WorkerStatusStyle {
        guard let w = worker else { return .idle }
        if !w.running { return .idle }
        if w.lastError != nil { return .attention }
        return .running
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedId, let idx = store.accounts.firstIndex(where: { $0.id == id }) {
            // Every walletDir already attached to *some other* Kiddo
            // account. The current account's own walletDir is allowed
            // to keep appearing in its own picker (so re-selecting
            // doesn't make it look "missing").
            let taken: Set<String> = Set(
                store.accounts
                    .filter { $0.id != id }
                    .map { $0.walletDir }
            )
            AccountEditor(
                saved: store.accounts[idx],
                worker: workers.worker(for: id),
                takenWalletDirs: taken,
                onSave: { committed in
                    // store.update handles the keychain hand-off:
                    // non-empty `password` → keychain, then scrub the
                    // in-memory field. We re-fetch the resulting
                    // (scrubbed) account so the worker snapshot
                    // doesn't carry plaintext into its next refresh.
                    store.update(committed)
                    if let scrubbed = store.accounts.first(where: { $0.id == committed.id }) {
                        workers.refresh(account: scrubbed)
                    }
                }
            )
            // .id forces SwiftUI to re-init AccountEditor's @State draft
            // when the user picks a different account in the sidebar.
            .id(id)
        } else {
            ContentUnavailableView(
                "No account selected",
                systemImage: "envelope",
                description: Text("Add an account with the + button to point Kiddo at a wallet directory.")
            )
        }
    }

    /// "+" handler. Branches on Option modifier — plain click adds a
    /// real-email account, Option-click prompts for the dev passcode
    /// and (on match) adds a FATMAMA account.
    ///
    /// `NSEvent.modifierFlags` returns the *current* global modifier
    /// state at call time, which is what a click handler sees — no
    /// need for a custom NSEvent monitor.
    private func addAccount() {
        if NSEvent.modifierFlags.contains(.option) {
            showPasscodeSheet = true
        } else {
            addEmailAccount()
        }
    }

    private func addEmailAccount() {
        var fresh = KiddoAccount.emailDefault
        fresh.id = UUID()
        fresh.label = "Account \(store.accounts.count + 1)"
        store.add(fresh)
        // Don't start the worker yet — the defaults have no host /
        // credentials, so polling would just spam connect-fail errors.
        // The worker spins up on first Save.
        selectedId = fresh.id
    }

    private func addDevAccount() {
        var fresh = KiddoAccount.devDefault
        fresh.id = UUID()
        fresh.label = "Account \(store.accounts.count + 1)"
        store.add(fresh)
        selectedId = fresh.id
    }

    private func removeSelected() {
        guard let id = selectedId else { return }
        workers.stop(id: id)
        store.remove(id)
        selectedId = nil
    }

    // ── Dev-account clean-up (Kiddo ↔ FATMAMA resync) ────────────────

    /// The dev class: `@axiom.internal` accounts (the FATMAMA path).
    /// Keyed on the email *domain* — the canonical dev-class rule
    /// (`isDevEmail`, mirroring `is_dev_wallet` / R1 in Core) — OR the
    /// stored `.axiomDev` kind, so a dev account whose email hasn't
    /// been filled in yet still counts. Real `.email` accounts are
    /// never in this set, so the clean-up can never touch them.
    private var devAccounts: [KiddoAccount] {
        store.accounts.filter { $0.kind == .axiomDev || KiddoAccount.isDevEmail($0.walletEmail) }
    }

    private var hasDevAccounts: Bool { !devAccounts.isEmpty }

    /// Resync every dev account across Kiddo + FATMAMA.
    ///
    /// The dev email carrier (FATMAMA relay ⇄ Kiddo) is fire-and-forget
    /// with no ack / retry, so a dropped `XAXIOM-REGISTER` or a stale
    /// `fatmama-mailbox-<slug>` can silently leave a wallet unable to
    /// collect witness responses (observed: a claim reaching < 3
    /// validators because the transport, not the protocol, dropped
    /// messages). This is the reset button: purge every dev route
    /// (Kiddo account + FATMAMA mailbox), then recreate one account per
    /// dev wallet on disk and re-register it. The AxiomWallet dirs under
    /// `wallets/` are the ground truth.
    ///
    /// **DEV-ONLY.** Only `@axiom.internal` / `.axiomDev` accounts are
    /// enumerated; `.email` accounts are never read, deleted, or
    /// recreated. FATMAMA additionally hard-protects validator routes
    /// server-side, so even a stray address can't knock a validator
    /// mailbox offline.
    private func cleanUpDevAccounts() {
        // Recreate spec — everything needed to rebuild one dev account
        // without re-reading the store after we've mutated it.
        struct DevSpec {
            let label: String
            let walletDir: String
            let walletEmail: String
            let smtpHost: String
            let smtpPort: Int
            let pop3Host: String
            let pop3Port: Int
        }

        let targets = devAccounts
        guard !targets.isEmpty else {
            cleanupStatus = "No dev accounts to clean up."
            return
        }
        NSLog("[Kiddo] clean-up start: %d dev account(s)", targets.count)

        // 1. Build recreate specs from the existing dev accounts, deduped
        //    by walletDir (one account per dev wallet — this is what
        //    collapses the duplicate accounts). Prefer the wallet's
        //    on-disk envelope email ("based on what was in the
        //    axiomwallet") over the stored one, but never resurrect a
        //    route that isn't dev-class after re-derivation.
        var specs: [DevSpec] = []
        var seenDirs = Set<String>()
        for a in targets {
            let std = (a.walletDir as NSString).standardizingPath
            if seenDirs.contains(std) { continue }
            let email = KiddoAccount.detectWalletEmail(walletDir: a.walletDir)
                ?? a.walletEmail
            guard KiddoAccount.isDevEmail(email) else { continue }
            specs.append(DevSpec(label: a.label, walletDir: a.walletDir,
                                 walletEmail: email, smtpHost: a.smtpHost,
                                 smtpPort: a.smtpPort, pop3Host: a.pop3Host,
                                 pop3Port: a.pop3Port))
            seenDirs.insert(std)
        }

        // Fold in any @axiom.internal wallet on disk that has no Kiddo
        // account yet, so the result is exactly one dev account per dev
        // wallet.
        let def = KiddoAccount.devDefault
        for cand in KiddoAccount.scanAvailableWallets(excluding: []) {
            let std = (cand.walletDir as NSString).standardizingPath
            if seenDirs.contains(std) { continue }
            guard let email = cand.walletEmail, KiddoAccount.isDevEmail(email) else { continue }
            specs.append(DevSpec(label: cand.displayName, walletDir: cand.walletDir,
                                 walletEmail: email, smtpHost: def.smtpHost,
                                 smtpPort: def.smtpPort, pop3Host: def.pop3Host,
                                 pop3Port: def.pop3Port))
            seenDirs.insert(std)
        }

        // FATMAMA routes to drop = every dev account's current mailbox
        // (its stored email, before re-derivation), lowercased + deduped.
        let dropEmails = Array(Set(
            targets.map { $0.walletEmail.lowercased() }.filter { !$0.isEmpty }
        ))
        // One FATMAMA relay fronts the whole dev env; take the first
        // non-empty SMTP host, else the dev default.
        let fatmamaHost = targets.first(where: { !$0.smtpHost.isEmpty })?.smtpHost
            ?? def.smtpHost
        let httpPort = FatmamaRoutes.defaultHttpPort

        // 2. Stop the dev workers up front (accounts stay VISIBLE in the
        //    list, just idle) so none of their 30s auto-re-registers
        //    (AccountWorker) races the FATMAMA delete below. The account
        //    swap happens at the very end, minimising the window where
        //    the list looks empty.
        let targetIds = targets.map { $0.id }
        for id in targetIds { workers.stop(id: id) }
        isCleaningDev = true
        cleanupStatus = "Cleaning \(targets.count) dev account(s) — talking to FATMAMA…"

        Task { @MainActor in
            // 3. Network legs off-main: delete stale FATMAMA routes (and
            //    their mailboxes), then register each fresh mailbox.
            let net: (delete: FatmamaDeleteSummary?, registered: Int, errors: [String]) =
                await Task.detached(priority: .userInitiated) {
                    var errors: [String] = []
                    var deleteSummary: FatmamaDeleteSummary? = nil
                    if !dropEmails.isEmpty, !fatmamaHost.isEmpty {
                        do {
                            deleteSummary = try FatmamaRoutes.delete(
                                host: fatmamaHost, httpPort: httpPort,
                                addrs: dropEmails, withMaildir: true)
                        } catch {
                            errors.append("FATMAMA delete: \(error.localizedDescription)")
                        }
                    }
                    var registered = 0
                    for s in specs {
                        guard !s.smtpHost.isEmpty, !s.walletEmail.isEmpty else { continue }
                        do {
                            try FatmamaRegister.register(host: s.smtpHost,
                                                         port: s.smtpPort,
                                                         email: s.walletEmail)
                            registered += 1
                        } catch {
                            errors.append("register \(s.walletEmail): "
                                + error.localizedDescription)
                        }
                    }
                    return (deleteSummary, registered, errors)
                }.value

            // 4. Swap the Kiddo side: remove the old dev accounts, add the
            //    fresh deduped set (fresh UUIDs). Their workers start and
            //    idempotently re-assert the routes we just registered.
            for id in targetIds { store.remove(id) }
            selectedId = nil
            for s in specs {
                var fresh = KiddoAccount.devDefault
                fresh.id = UUID()
                fresh.kind = .axiomDev
                fresh.label = s.label
                fresh.walletDir = s.walletDir
                fresh.walletEmail = s.walletEmail
                fresh.smtpHost = s.smtpHost
                fresh.smtpPort = s.smtpPort
                fresh.pop3Host = s.pop3Host
                fresh.pop3Port = s.pop3Port
                store.add(fresh)
            }

            isCleaningDev = false
            let delN = net.delete?.deleted ?? 0
            NSLog("[Kiddo] clean-up done: fatmama_deleted=%d registered=%d recreated=%d errors=%d",
                  delN, net.registered, specs.count, net.errors.count)
            if net.errors.isEmpty {
                cleanupStatus = "Done — dropped \(delN) FATMAMA route(s), "
                    + "recreated \(specs.count) account(s), re-registered "
                    + "\(net.registered). Kiddo ↔ FATMAMA back in sync."
            } else {
                cleanupStatus = "Recreated \(specs.count), re-registered "
                    + "\(net.registered), dropped \(delN) — "
                    + "\(net.errors.count) issue(s): "
                    + net.errors.prefix(2).joined(separator: "; ")
            }
        }
    }
}

private struct AccountEditor: View {
    /// The committed (persisted) account. Drives the Revert button +
    /// the dirty indicator.
    let saved: KiddoAccount
    let worker: AccountWorker?
    /// walletDirs already attached to *other* accounts — excluded
    /// from the "Pick wallet…" menu so the user can't double-attach
    /// the same wallet.
    let takenWalletDirs: Set<String>
    let onSave: (KiddoAccount) -> Void

    /// Live editing buffer. Initialized from `saved` once at view
    /// construction; the `.id(account.id)` modifier in the parent
    /// forces re-init when switching accounts.
    @State private var draft: KiddoAccount

    /// Transient status line for the "Register with FATMAMA" button.
    /// Nil = idle. Non-nil = either an in-flight message
    /// ("Registering…") or the last result. Cleared automatically
    /// when the user edits walletEmail again.
    @State private var fatmamaStatus: String?
    @State private var isRegisteringFatmama: Bool = false

    /// Pending transport-directory wipe awaiting confirmation. Set by
    /// the Clean send / Clean receive buttons; cleared on confirm or
    /// cancel. Drives the destructive confirmation dialog.
    @State private var cleanTarget: CleanTarget? = nil

    /// The two transport directions a `Clean …` button resets — a dev
    /// convenience for wiping a wallet's outbox / inbox when a
    /// development session leaves the maildir in a strange state.
    private enum CleanTarget: Identifiable {
        case send, receive
        var id: Int { self == .send ? 0 : 1 }
        /// Subdirectories (relative to the wallet dir) this target empties.
        var subdirs: [String] {
            switch self {
            case .send:    return ["outbox/new", "outbox/sending", "outbox/sent", "outbox/failed"]
            case .receive: return ["maildir/inbox/new", "maildir/inbox/cur"]
            }
        }
        var label: String { self == .send ? "send queue" : "receive inbox" }
    }

    init(saved: KiddoAccount, worker: AccountWorker?,
         takenWalletDirs: Set<String>,
         onSave: @escaping (KiddoAccount) -> Void) {
        self.saved = saved
        self.worker = worker
        self.takenWalletDirs = takenWalletDirs
        self.onSave = onSave
        self._draft = State(initialValue: saved)
    }

    private var isDirty: Bool { draft != saved }

    private var kindHeader: String {
        switch draft.kind {
        case .email:    return "Identity (real email)"
        case .axiomDev: return "Identity (AXIOM dev env)"
        }
    }

    /// Caption under the Identity section. Both kinds get the
    /// wallet-picker hint; `.axiomDev` accounts additionally get a
    /// pointer to the FATMAMA register button.
    private var identityCaption: String {
        let pickerHint = "Pick from any wallet in `~/Library/Application Support/Axiom/wallets/` that isn't already attached to another Kiddo account. The wallet's own email is auto-filled from the first `.eml` in its outbox / inbox."
        switch draft.kind {
        case .email:
            return pickerHint
        case .axiomDev:
            return pickerHint + " Click `Register with FATMAMA` once the email is set so the dev SMTP relay routes inbound mail for this address — replaces the manual `fatmama-routes.json` edit on the dev box."
        }
    }

    /// Fire the FATMAMA `XAXIOM-REGISTER <email>` SMTP verb on a
    /// background queue so the UI stays responsive. Surfaces a
    /// transient status line in the Identity section regardless of
    /// outcome — connect failure / non-250 / OK.
    private func registerWithFatmama() {
        let host = draft.smtpHost
        let port = draft.smtpPort
        let email = draft.walletEmail
        guard !host.isEmpty, !email.isEmpty else { return }

        isRegisteringFatmama = true
        fatmamaStatus = "Registering with \(host):\(port)…"

        // Detached Task runs the blocking SMTP I/O off-main; the
        // outer `Task { @MainActor }` block awaits and applies the
        // result back on main. SwiftUI's @State storage is reference-
        // backed so the mutation surfaces in the rendered view.
        Task { @MainActor in
            let result: String = await Task.detached(priority: .userInitiated) {
                do {
                    try FatmamaRegister.register(
                        host: host, port: port, email: email
                    )
                    return "OK — \(email) is now registered with FATMAMA"
                } catch {
                    return "Failed: \(error.localizedDescription)"
                }
            }.value
            fatmamaStatus = result
            isRegisteringFatmama = false
        }
    }

    /// Presentational only — derives "the last registration failed"
    /// from the same status string `registerWithFatmama` writes on
    /// its catch path ("Failed: …"). No new state.
    private func isFatmamaFailure(_ status: String) -> Bool {
        status.hasPrefix("Failed")
    }

    /// Auth-section footer. Shape mirrors the keychain state so the
    /// user knows whether typing a value will create or replace.
    private var authCaption: String {
        let baseTransport = "Used for SMTP AUTH PLAIN and POP3 USER/PASS over implicit TLS (SMTPS 465 / POP3S 995). STARTTLS-only ports like SMTP 587 don't work yet — use 465 instead. For Gmail-style providers use an app-specific password, not your account password."
        if draft.hasKeychainPassword {
            return "Password is stored in the macOS Keychain — never in accounts.json. Type a new value above to replace it; leave blank to keep the existing one. " + baseTransport
        } else {
            return "Password will be stored in the macOS Keychain on Save — never written to accounts.json. " + baseTransport
        }
    }

    /// Available wallets in `~/Library/Application Support/Axiom/wallets/`
    /// not currently attached to *other* Kiddo accounts. Scanned on
    /// every render — cheap (a handful of directories, one stat per
    /// .eml at most) and keeps the menu live as the user creates /
    /// removes wallets in the wallet app.
    private var availableWallets: [WalletCandidate] {
        KiddoAccount.scanAvailableWallets(excluding: takenWalletDirs)
    }

    /// Menu of every unassigned wallet on disk. Picking one fills
    /// both `walletDir` (the absolute path) and `walletEmail` (the
    /// envelope-detected address, when present). If nothing matches
    /// it falls through to a disabled hint row.
    @ViewBuilder
    private var walletPickerMenu: some View {
        let candidates = availableWallets
        Menu("Pick wallet…") {
            if candidates.isEmpty {
                Text("No unassigned wallets in default directory")
            } else {
                ForEach(candidates) { w in
                    Button {
                        applyCandidate(w)
                    } label: {
                        if let email = w.walletEmail, !email.isEmpty {
                            Text("\(w.displayName) — \(email)")
                        } else {
                            Text("\(w.displayName) — (no envelope yet)")
                        }
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func applyCandidate(_ w: WalletCandidate) {
        draft.walletDir = w.walletDir
        if let email = w.walletEmail, !email.isEmpty {
            draft.walletEmail = email
        }
        // Picking a wallet may flip the class — run the same
        // auto-detect that fires on manual email edits.
        adaptKindToEmail()
    }

    /// True when the typed wallet email belongs to the developer
    /// class (`@axiom.internal` exactly, case-insensitive on the
    /// domain only). Mirrors `axiom_core_logic::wallet_id::is_dev_wallet`
    /// — same string-comparison rule that R1 enforces in Core, but
    /// re-implemented locally because Kiddo deliberately doesn't
    /// link AxiomSdk (Package.swift comment). One source of truth
    /// for the rule itself lives in
    /// `docs/AXIOM_DESIGN_FactClassIsolation.md` §2.
    private func isDevEmail(_ email: String) -> Bool {
        guard let atIdx = email.firstIndex(of: "@") else { return false }
        let domain = email[email.index(after: atIdx)...].lowercased()
        return domain == "axiom.internal"
    }

    /// Auto-adapt the account preset to match the wallet email's
    /// class. Fires on every change to `draft.walletEmail` and
    /// on wallet-picker selection. If the class implied by the
    /// email differs from the current `draft.kind`, the relevant
    /// `KiddoAccount.devDefault` / `.emailDefault` preset is applied
    /// — but user-set fields (label, walletDir, walletEmail,
    /// username, password, hasKeychainPassword, pop3PollSecs) are
    /// preserved. Host / port / TLS settings get the preset's
    /// values; the user can override afterward if they need
    /// non-default ports.
    private func adaptKindToEmail() {
        let targetKind: AccountKind = isDevEmail(draft.walletEmail)
            ? .axiomDev : .email
        if draft.kind == targetKind { return }

        // Snapshot the user-controlled fields before applying the
        // preset so we can restore them.
        let label   = draft.label
        let dir     = draft.walletDir
        let email   = draft.walletEmail
        let user    = draft.username
        let pw      = draft.password
        let hasPw   = draft.hasKeychainPassword
        let poll    = draft.pop3PollSecs

        let preset = (targetKind == .axiomDev)
            ? KiddoAccount.devDefault
            : KiddoAccount.emailDefault
        draft.kind       = preset.kind
        draft.smtpHost   = preset.smtpHost
        draft.smtpPort   = preset.smtpPort
        draft.smtpUseTLS = preset.smtpUseTLS
        draft.pop3Host   = preset.pop3Host
        draft.pop3Port   = preset.pop3Port
        draft.pop3UseTLS = preset.pop3UseTLS

        draft.label              = label
        draft.walletDir          = dir
        draft.walletEmail        = email
        draft.username           = user
        draft.password           = pw
        draft.hasKeychainPassword = hasPw
        draft.pop3PollSecs       = poll
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(kindHeader) {
                    TextField("Label", text: $draft.label)
                    HStack {
                        TextField("Wallet email", text: $draft.walletEmail,
                                  prompt: Text("alice@axiom"))
                            .textFieldStyle(.roundedBorder)
                            .font(KiddoTokens.Typography.mono)
                            .onChange(of: draft.walletEmail) { _, _ in
                                // Stale status when the address changes
                                // — last result no longer reflects what
                                // the button would do now.
                                fatmamaStatus = nil
                                // Class auto-detect: @axiom.internal
                                // emails flip the account to axiomDev
                                // preset, anything else flips back to
                                // email preset. See
                                // `AXIOM_DESIGN_FactClassIsolation.md`.
                                adaptKindToEmail()
                            }
                        walletPickerMenu
                    }

                    // Show an inline notice when the class has been
                    // auto-detected from the email's domain — gives the
                    // user visible confirmation of the preset switch.
                    if isDevEmail(draft.walletEmail) {
                        HStack(spacing: KiddoTokens.Spacing.xxs) {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(KiddoTokens.Typography.caption)
                                // Informational notice, not a worker
                                // status — brand accent, never a
                                // status color (one meaning per color).
                                .foregroundStyle(KiddoTokens.accent)
                            Text("Detected `@axiom.internal` — using FATMAMA defaults (port 2525 / 2527, no TLS).")
                                .font(KiddoTokens.Typography.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                    // FATMAMA register button — only for the dev/axiomDev
                    // path. Sends `XAXIOM-REGISTER <email>` to the dev
                    // SMTP relay so it accepts inbound mail + queues for
                    // POP3 polling. Closes the manual fatmama-routes.json
                    // edit step that's been the single biggest snag for
                    // onboarding new testers.
                    if draft.kind == .axiomDev {
                        HStack(spacing: KiddoTokens.Spacing.xs) {
                            Button(action: registerWithFatmama) {
                                Label("Register with FATMAMA",
                                      systemImage: "paperplane.fill")
                            }
                            .disabled(draft.walletEmail.isEmpty
                                      || draft.smtpHost.isEmpty
                                      || isRegisteringFatmama)
                            // Purely presentational — driven by the
                            // existing in-flight flag the register
                            // action already maintains.
                            if isRegisteringFatmama {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("Registering with FATMAMA")
                            }
                            if let status = fatmamaStatus {
                                if isFatmamaFailure(status) {
                                    Image(systemName: WorkerStatusStyle.attention.symbol)
                                        .foregroundStyle(KiddoTokens.statusAttentionFg)
                                        .accessibilityHidden(true)
                                    Text(status)
                                        .font(KiddoTokens.Typography.caption)
                                        .foregroundStyle(KiddoTokens.statusAttentionFg)
                                        .lineLimit(2)
                                    // Same action as the primary
                                    // button — no new logic.
                                    Button("Retry", action: registerWithFatmama)
                                        .buttonStyle(.bordered)
                                        .disabled(draft.walletEmail.isEmpty
                                                  || draft.smtpHost.isEmpty
                                                  || isRegisteringFatmama)
                                } else {
                                    Text(status)
                                        .font(KiddoTokens.Typography.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                        }
                    }
                    Text(identityCaption)
                        .font(KiddoTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Wallet directory") {
                    HStack {
                        TextField("/Users/.../wallets/<pair>-normal",
                                  text: $draft.walletDir)
                            .font(KiddoTokens.Typography.mono)
                        Button("Pick…") { pickDir() }
                    }
                    Text("Kiddo watches `<dir>/outbox/new/` and drops inbound mail into `<dir>/maildir/inbox/new/`.")
                        .font(KiddoTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                Section(draft.kind == .email
                        ? "SMTP (outbound, TLS)"
                        : "SMTP (outbound)") {
                    TextField("Host", text: $draft.smtpHost)
                    TextField("Port", value: $draft.smtpPort, formatter: NumberFormatter())
                        .frame(minWidth: 80, maxWidth: 120)
                    if draft.kind == .email {
                        Toggle("Use TLS", isOn: $draft.smtpUseTLS)
                    }
                }

                Section(draft.kind == .email
                        ? "POP3 (inbound, TLS)"
                        : "POP3 (inbound)") {
                    TextField("Host", text: $draft.pop3Host)
                    TextField("Port", value: $draft.pop3Port, formatter: NumberFormatter())
                        .frame(minWidth: 80, maxWidth: 120)
                    if draft.kind == .email {
                        Toggle("Use TLS", isOn: $draft.pop3UseTLS)
                    }
                    Stepper(value: $draft.pop3PollSecs, in: 1...60) {
                        Text("Poll interval: \(draft.pop3PollSecs)s")
                    }
                }

                // Credentials only live on real-email accounts. The
                // dev / FATMAMA path has no auth — fields stay hidden
                // and unused.
                //
                // Phase 1: password persists in accounts.json as
                // plaintext. Phase 3 will move it to the macOS
                // Keychain and store only a presence flag here.
                if draft.kind == .email {
                    Section("Authentication") {
                        TextField("Username", text: $draft.username,
                                  prompt: Text("alice@example.com"))
                            .textContentType(.username)
                            .font(KiddoTokens.Typography.mono)
                        SecureField(
                            // Different prompt depending on whether
                            // the keychain already holds a password —
                            // matches Apple-style "leave blank to
                            // keep" semantics.
                            draft.hasKeychainPassword
                                ? "Stored — type to replace"
                                : "Password / app password",
                            text: $draft.password
                        )
                        Text(authCaption)
                            .font(KiddoTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let w = worker {
                    Section("Status") {
                        statusRow("Total sent", "\(w.totalSent)")
                        statusRow("Total pulled", "\(w.totalPulled)")
                        statusRow("Queue depth (new)", "\(w.queueDepth)")
                        statusRow("Failed (quarantine)", "\(failedCount(saved.walletDir))")
                        statusRow("Last send", w.lastSendAt.map(timeAgo) ?? "—")
                        statusRow("Last pull", w.lastPullAt.map(timeAgo) ?? "—")
                        if let err = w.lastError {
                            // lastError != nil is the attention
                            // condition — symbol + color from the one
                            // canonical status mapping.
                            statusRow("Last error", err,
                                      color: KiddoTokens.statusAttentionFg,
                                      symbol: WorkerStatusStyle.attention.symbol)
                        }
                        HStack(spacing: KiddoTokens.Spacing.xs) {
                            Button {
                                w.forceDrain()
                            } label: {
                                Label("Drain outbox now", systemImage: "arrow.triangle.2.circlepath")
                            }
                            Button {
                                w.retryFailed()
                            } label: {
                                Label("Retry failed (\(failedCount(saved.walletDir)))",
                                      systemImage: "arrow.uturn.up")
                            }
                            .disabled(failedCount(saved.walletDir) == 0)
                            Spacer()
                        }
                        .padding(.top, KiddoTokens.Spacing.xxs)
                    }
                }

                Section("Maintenance") {
                    Text("Reset this wallet's transport queues — for when a dev session leaves the maildir in a strange state. Destructive: a queued send or an unread response is deleted, and it can't be undone.")
                        .font(KiddoTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: KiddoTokens.Spacing.xs) {
                        Button(role: .destructive) {
                            cleanTarget = .send
                        } label: {
                            Label("Clean send (\(fileCount(.send)))",
                                  systemImage: "trash")
                        }
                        .disabled(draft.walletDir.isEmpty || fileCount(.send) == 0)
                        Button(role: .destructive) {
                            cleanTarget = .receive
                        } label: {
                            Label("Clean receive (\(fileCount(.receive)))",
                                  systemImage: "trash")
                        }
                        .disabled(draft.walletDir.isEmpty || fileCount(.receive) == 0)
                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            actionBar
        }
        .onAppear {
            if draft.walletEmail.isEmpty {
                autoDetectEmail()
            }
        }
        // When the parent commits a save, `saved` becomes the
        // scrubbed-password version. Without this reset, the editor's
        // `draft` still carries the user-typed password, `isDirty`
        // stays true, and "Unsaved changes" lingers. Resetting draft
        // = saved closes the cycle and shows the stored-keychain
        // placeholder.
        .onChange(of: saved) { _, newSaved in
            draft = newSaved
        }
        .confirmationDialog(
            "Clean \(cleanTarget?.label ?? "")?",
            isPresented: Binding(
                get: { cleanTarget != nil },
                set: { if !$0 { cleanTarget = nil } }
            ),
            presenting: cleanTarget
        ) { target in
            Button("Delete \(fileCount(target)) file(s)", role: .destructive) {
                performClean(target)
                cleanTarget = nil
            }
            Button("Cancel", role: .cancel) { cleanTarget = nil }
        } message: { target in
            Text("Permanently empties this wallet's \(target.label) — \(target.subdirs.joined(separator: ", ")). A queued send or unread response would be lost. Dev reset; can't be undone.")
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack {
            if isDirty {
                HStack(spacing: KiddoTokens.Spacing.xxs) {
                    Circle()
                        .fill(KiddoTokens.statusAttentionFg)
                        .frame(width: KiddoTokens.Size.statusDot,
                               height: KiddoTokens.Size.statusDot)
                    Text("Unsaved changes")
                        .font(KiddoTokens.Typography.caption)
                        .foregroundStyle(KiddoTokens.statusAttentionFg)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Unsaved changes")
                .help("Unsaved changes")
            }
            Spacer()
            Button("Revert") {
                draft = saved
            }
            .disabled(!isDirty)

            Button("Save") {
                onSave(draft)
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!isDirty)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, KiddoTokens.Spacing.md)
        .padding(.vertical, KiddoTokens.Spacing.xs)
        .background(.thinMaterial)
    }

    private func statusRow(_ label: String, _ value: String,
                           color: Color = .primary,
                           symbol: String? = nil) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            }
            Text(value)
                .font(KiddoTokens.Typography.mono)
                .foregroundStyle(color)
        }
    }

    private func pickDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Select wallet directory"
        if panel.runModal() == .OK, let url = panel.url {
            draft.walletDir = url.path
            // If user picks a dir and email isn't set yet, opportunistic
            // detection — the typical single-wallet flow ends up needing
            // only the dir picked + Save clicked.
            if draft.walletEmail.isEmpty {
                autoDetectEmail()
            }
        }
    }

    private func autoDetectEmail() {
        if let detected = KiddoAccount.detectWalletEmail(walletDir: draft.walletDir),
           !detected.isEmpty {
            draft.walletEmail = detected
        }
    }

    /// Count of files currently in `<walletDir>/outbox/failed/`. Read
    /// from disk on every render so the status row + button label
    /// stay live. Cheap (typical count is 0–single-digit).
    private func failedCount(_ walletDir: String) -> Int {
        let fm = FileManager.default
        let path = "\(walletDir)/outbox/failed"
        return (try? fm.contentsOfDirectory(atPath: path).count) ?? 0
    }

    /// Total files across one `CleanTarget`'s subdirectories of the
    /// draft's wallet dir. Recomputed every render (cheap — a handful
    /// of dirs) so the Clean button labels stay live.
    private func fileCount(_ target: CleanTarget) -> Int {
        let fm = FileManager.default
        return target.subdirs.reduce(0) { acc, sub in
            let items = (try? fm.contentsOfDirectory(
                atPath: "\(draft.walletDir)/\(sub)")) ?? []
            return acc + items.count
        }
    }

    /// Delete every file in `target`'s subdirectories. Leaves the
    /// directories themselves in place — the wallet and the worker
    /// expect them to exist. Best-effort: a file locked by an in-flight
    /// poll is skipped rather than aborting the wipe.
    @discardableResult
    private func performClean(_ target: CleanTarget) -> Int {
        let fm = FileManager.default
        var removed = 0
        for sub in target.subdirs {
            let dir = "\(draft.walletDir)/\(sub)"
            let items = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for item in items {
                do {
                    try fm.removeItem(atPath: "\(dir)/\(item)")
                    removed += 1
                } catch {
                    // skip — locked / vanished mid-wipe
                }
            }
        }
        return removed
    }

    private func timeAgo(_ d: Date) -> String {
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 5 { return "just now" }
        if secs < 60 { return "\(secs)s ago" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m ago" }
        let hrs = mins / 60
        return "\(hrs)h ago"
    }
}

// =================================================================
// PasscodeGateSheet — Option-click "+" passcode prompt.
//
// Modal sheet with one SecureField and Cancel / OK. Calls `onSubmit`
// exactly once with whatever the user typed (including empty), then
// the caller dismisses + decides whether the value matches.
//
// Cover rules: the title is intentionally bland ("Enter passcode"),
// the placeholder doesn't hint at what's being unlocked, and a
// wrong passcode dismisses silently — no toast, no error label, no
// shake. A casual user who Option-clicks just sees a passcode
// prompt with no context, types nothing or wrong, and is back
// where they started.
// =================================================================
private struct PasscodeGateSheet: View {
    let onSubmit: (String) -> Void
    @State private var entered: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: KiddoTokens.Spacing.sm) {
            Text("Enter passcode")
                .font(KiddoTokens.Typography.heading)
            SecureField("Passcode", text: $entered)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button("Cancel") {
                    entered = ""
                    onSubmit("")
                }
                .keyboardShortcut(.cancelAction)
                Button("OK") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(KiddoTokens.Spacing.lg)
        .frame(width: 340)
    }

    private func submit() {
        let v = entered
        entered = ""
        onSubmit(v)
    }
}
