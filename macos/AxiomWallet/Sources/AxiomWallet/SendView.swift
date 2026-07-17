import SwiftUI
import AxiomSdk

// =================================================================
// SendView — outgoing payment composition + sign-and-broadcast.
//
// Mirrors views/02_send.html: send-from card (active wallet) +
// recipient field with live tier auto-decode + amount field with
// AXC equivalence + reference textarea + warning copy + Cancel /
// Sign-and-send buttons.
//
// Sign-and-send opens 10_sign_modal.html: TX summary + 2FA wallet_key
// challenge + final broadcast button. Wallet key verifies via the
// existing FFI; the actual send call is stubbed in this commit
// (Mac dev does not yet have a validator-mesh transport path —
// FATMAMA isn't reachable from this Mac, so wallet.send() would
// fail with NetworkTimeout regardless). The pre-flight discipline
// is the real value: recipient tier auto-decoded, amount validated
// against balance, password gate enforced.
//
// Per the integration rule: every cell of data shown here came from
// FFI (active wallet + decode_address). When the validator
// transport path lands, only the broadcast action changes — the
// pre-flight stays.
// =================================================================

struct SendView: View {
    @EnvironmentObject private var session: AppSession
    /// One send at a time — the Sign button is disabled while a
    /// background send is still running.
    @EnvironmentObject private var sendCoordinator: SendCoordinator
    /// One broadcast at a time — sending while a redeem is in
    /// flight would be two parallel wallet TXs (YP §32 fork risk).
    /// Sign button greys out when isRedeeming.
    @EnvironmentObject private var redeemCoordinator: RedeemCoordinator
    /// One broadcast at a time — a genesis claim is also a wallet TX
    /// (YP §32). Sign button greys out while a claim is in flight.
    @EnvironmentObject private var claimCoordinator: ClaimCoordinator
    /// Release-feed checker. When the network's Core has rotated
    /// (`mustUpgradeCore`), Send is locked — see canSign.
    @EnvironmentObject private var releaseUpdate: ReleaseUpdateWatcher
    /// L$ digit_version change — gates the next 3 sends with a verify
    /// prompt (see proceedToSign + dvWarningSheet).
    @EnvironmentObject private var digitVersion: DigitVersionWatcher
    /// App-scoped contacts store (see AxiomWalletApp). Was @StateObject
    /// per-view, but that meant Send's in-memory cache went stale
    /// the moment the user added a contact in ContactsView — the
    /// recipient picker disappeared because Send's local copy of
    /// `contacts` was still empty. Shared instance fixes the gap.
    @EnvironmentObject private var contactsStore: ContactsStore
    /// Scar-consent ledger — records the completed consent send so the
    /// Activity log can label it (YPX-001 §1.5.1).
    @EnvironmentObject private var scarConsentStore: ScarConsentStore

    /// Which denomination the user is currently typing the amount in.
    /// The protocol stores everything in atoms; this only changes how
    /// `amountText` parses and how the cross-reference subtitle reads.
    enum AmountUnit: String, CaseIterable, Identifiable {
        case lDollar = "L$"
        case axc     = "AXC"
        var id: String { rawValue }
    }

    @State private var recipient: String = ""
    @State private var amountText: String = ""
    @State private var amountUnit: AmountUnit = .lDollar
    @State private var reference: String = ""
    @State private var showSignSheet: Bool = false
    /// Pre-send L$ digit_version verify gate (next 3 sends after a change).
    @State private var showDvWarning: Bool = false
    /// Set when the YPX-007 §10 pre-flight catches a ZKP-tier send
    /// against a prior witness set with insufficient ZKP-capable
    /// overlap. Driving the consent sheet that warns the user about
    /// the latency cost before invoking the actual send. nil → no
    /// warning needed, Send proceeds straight to SignModal.
    @State private var tierWarning: TierWarningRow? = nil
    /// The contact the user picked from the picker, if any. When
    /// non-nil, the recipient field is pre-filled from `address` and
    /// the contact's `deliveryEmail` is held for a future `receiver_address`
    /// FFI plumbing (SDK `SendConfig` needs the field exposed; pending
    /// — see CLAUDE.md §14 / TransportLayer doc for the contact-routing
    /// gap). Today selecting a contact saves typing the address; the
    /// override email is captured but not yet shipped on the TX.
    @State private var selectedContactId: UUID? = nil
    /// Drives the search-able contact picker sheet. Replaces the old
    /// inline Menu — a Menu becomes unscannable past ~5 contacts (no
    /// keyboard search, all rows rendered as one column).
    @State private var showContactPicker: Bool = false
    /// Hover feedback for the "Pick contact" text button (visual only).
    @State private var pickContactHovered: Bool = false

    /// Kiddo pre-flight gate. Send writes UMP envelopes to outbox/
    /// and depends on Kiddo to relay them via SMTP. If Kiddo isn't
    /// running, the wallet would hang silently waiting for cheques
    /// that never come. The gate runs at "Sign" button time;
    /// on non-ready states, the .kiddoGateAlert renders + offers the
    /// "Launch Kiddo" action before the actual send begins.
    @StateObject private var kiddoGate = KiddoGate()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                // "SEND FROM" card removed 2026-05-25 — the Overview
                // chrome's balance hero is always visible above this
                // panel and already shows pair / mode / balance.
                if let r = resumable { resumableSendCard(r) }
                if let s = scarPending { scarConsentCard(s) }
                recipientCard
                if classMismatch { classMismatchWarning }
                amountAndScheduleRow
                referenceCard
                warningCopy
                actionRow
            }
            .padding(EdgeInsets(top: DesignTokens.Spacing.lg, leading: DesignTokens.Spacing.xl, bottom: DesignTokens.Spacing.lg, trailing: DesignTokens.Spacing.xl))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.bgPrimary)
        .onAppear { refreshResumable() }
        // Re-check after any send resolves — a timeout persists a round,
        // a completed round consumes it, a fresh send abandons it.
        .onReceive(sendCoordinator.$lastOutcome) { outcome in
            refreshResumable()
            handleScarOutcome(outcome)
        }
        .onReceive(sendCoordinator.$active) { _ in refreshResumable() }
        // YPX-001 §1.5.1 passcode entry — presented on the initial pause
        // and re-openable from the pending card. The FFI call runs in
        // SendCoordinator (app-scoped, off-main): closing this sheet
        // never kills the round.
        .sheet(isPresented: $showScarConsentSheet) {
            if let s = scarPending, s.current {
                ScarConsentSheet(
                    row: s,
                    onCancel: { showScarConsentSheet = false },
                    onSubmit: { code in
                        showScarConsentSheet = false
                        guard let wallet = session.activeWallet else { return }
                        sendCoordinator.completeScarConsent(
                            wallet: wallet, pending: s, passcode: code,
                            ledger: scarConsentStore)
                    }
                )
            }
        }
        .sheet(isPresented: $showSignSheet) {
            SignModal(
                recipient: recipient,
                amountAtoms: parsedAmountAtoms ?? 0,
                amountUnit: amountUnit,
                tier: tier,
                reference: reference,
                deliveryEmailOverride: pickedContact?.deliveryEmail.isEmpty == false
                    ? pickedContact?.deliveryEmail
                    : nil,
                contactName: pickedContact?.name,
                onCancel: { showSignSheet = false },
                onCompletion: { showSignSheet = false }
            )
        }
        .sheet(isPresented: $showDvWarning) { dvWarningSheet() }
        // YPX-007 §10.3 ZKP-tier slow-witness warning. Presented
        // BEFORE the SignModal so the user knows the latency cost
        // and the lower-tier-address alternative before they commit
        // to entering their wallet key. Nothing about the send has
        // started yet; cancelling here is free.
        .sheet(isPresented: Binding(
            get: { tierWarning != nil },
            set: { newVal in if !newVal { tierWarning = nil } }
        )) {
            if let w = tierWarning {
                zkpTierWarningSheet(warning: w)
            }
        }
        .sheet(isPresented: $showContactPicker) {
            ContactPickerSheet(
                contacts: pickableContacts,
                currentlyPickedId: selectedContactId,
                onPick: { contact in
                    pickContact(contact)
                    showContactPicker = false
                },
                onCancel: { showContactPicker = false }
            )
        }
        .kiddoGateAlert(kiddoGate)
    }

    /// Contacts offered in the recipient picker — everything EXCEPT the
    /// sending wallet's own address.
    ///
    /// The address book now auto-carries this Mac's own wallets, so the
    /// wallet you're sending FROM appears in it. Core's Rule 4 rejects a
    /// send to your own address (`SelfSendRejected`; only heal / genesis
    /// claim / HAL re-anchor / recall are exempt), so offering that row
    /// would be offering a guaranteed failure. Your OTHER wallets stay —
    /// they're ordinary counterparties to this one, which is the whole
    /// point of auto-adding them.
    ///
    /// Filtered by address, not by contact id: a user-added row holding
    /// the same address must drop out too.
    private var pickableContacts: [Contact] {
        // `try?` on an optional chain flattens, so this is one String?, not two.
        guard let own = try? session.activeWallet?.address() else {
            return contactsStore.contacts
        }
        return contactsStore.contacts.filter { $0.address != own }
    }

    // MARK: - Resumable interrupted send (late-response salvage, 2026-07-07)

    /// The interrupted-but-still-valid send round, if any. Witnessing has
    /// no protocol expiry — a per-hop timeout just means the app stopped
    /// waiting, and responses that arrived later still count. Refreshed on
    /// pane entry and after every send outcome. Latest-wins: starting a
    /// new send abandons this round (the SDK discards it).
    @State private var resumable: ResumableSendRow? = nil

    private func refreshResumable() {
        resumable = session.activeWallet?.resumableSend()
        refreshScarPending()
    }

    // MARK: - Scar-consent paused send (YPX-001 §1.5.1)

    /// The scar-consent-paused send, if any — a payment the overlapped
    /// validator gated because the money carries unresolved scar(s). The
    /// receiver holds the 6-digit passcode; the payment completes only
    /// through `sendWithScarPasscode`. Refreshed alongside `resumable`
    /// (same disk-truth pattern: the SDK's scar_pending record IS the
    /// state; no in-memory flag to drift).
    @State private var scarPending: PendingScarSendRow? = nil
    /// Drives the passcode-entry sheet. Auto-opened when a send resolves
    /// with the initial ScarConsentRequired pause; re-opened by the user
    /// from the pending card (e.g. after a wrong-passcode rejection).
    @State private var showScarConsentSheet: Bool = false

    private func refreshScarPending() {
        scarPending = session.activeWallet?.pendingScarSend()
    }

    /// Auto-open the passcode sheet when a send just paused for consent
    /// (initial pause only — wrong-passcode rejections keep the card up
    /// but let the user decide when to re-enter; the banner already says
    /// what happened).
    private func handleScarOutcome(_ outcome: SendCoordinator.Outcome?) {
        guard case .failed(let code, let msg) = outcome,
              ScarConsent.isScarConsent(code: code),
              !ScarConsent.isWrongPasscode(message: msg),
              !ScarConsent.isTransientHop(message: msg) else { return }
        refreshScarPending()
        if scarPending?.current == true {
            showScarConsentSheet = true
        }
    }

    @ViewBuilder
    private func scarConsentCard(_ r: PendingScarSendRow) -> some View {
        ScarConsentPendingCard(
            row: r,
            enterDisabled: sendCoordinator.isSending
                || redeemCoordinator.isRedeeming
                || claimCoordinator.isClaiming
                || session.isHibernating,
            onEnterPasscode: { showScarConsentSheet = true },
            onDiscard: {
                session.activeWallet?.discardPendingScarSend()
                scarPending = nil
            }
        )
    }

    @ViewBuilder
    private func resumableSendCard(_ r: ResumableSendRow) -> some View {
        // Shared component (ResumableSendCard.swift) so the dev-tools
        // "Send-state reference" renders the SAME view — the reference
        // never drifts from what users actually see.
        ResumableSendCard(
            row: r,
            resumeDisabled: sendCoordinator.isSending
                || redeemCoordinator.isRedeeming
                || claimCoordinator.isClaiming
                || session.isHibernating,
            onResume: {
                guard let wallet = session.activeWallet else { return }
                sendCoordinator.resume(wallet: wallet, resumable: r)
                resumable = nil
            },
            onDiscard: {
                session.activeWallet?.discardResumableSend()
                resumable = nil
            }
        )
    }

    // MARK: - Recipient card

    private var recipientCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RECIPIENT")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Spacer()
                if !contactsStore.contacts.isEmpty {
                    pickContactButton
                }
            }

            // When a contact is picked, surface their NAME prominently
            // above the address field. The address alone (e.g.,
            // `ann@axiom.internal/d1c5ae0d79`) doesn't tell the user
            // who they're actually sending to — the banner closes
            // that gap with avatar + name + a Change/Clear affordance.
            if let pickedContact {
                pickedContactBanner(pickedContact)
            }

            TextField("recipient@example.com/<10 hex>", text: $recipient)
                .textFieldStyle(.roundedBorder)
                .font(DesignTokens.Typography.mono)
                .autocorrectionDisabled()
                .onChange(of: recipient) { _, _ in
                    // User edited the field manually — drop the
                    // contact binding so the override email doesn't
                    // travel with a now-different address.
                    selectedContactId = nil
                }

            if let pickedContact, !pickedContact.deliveryEmail.isEmpty {
                contactDeliveryNote(pickedContact)
            }

            if !recipient.isEmpty {
                tierBadgeRow
            }
        }
    }

    /// "Pick contact" button that opens the search-able sheet. Replaces
    /// the old inline Menu which didn't scale past a handful of
    /// contacts (no keyboard search, one flat column).
    private var pickContactButton: some View {
        Button(action: { showContactPicker = true }) {
            HStack(spacing: DesignTokens.Spacing.xxs) {
                Image(systemName: "person.crop.circle")
                Text(selectedContactId == nil ? "Pick contact" : "Change contact")
            }
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.brandPrimary)
        }
        .buttonStyle(.plain)
        .opacity(pickContactHovered ? 0.72 : 1.0)
        .onHover { inside in
            withAnimation(DesignTokens.Motion.quick()) {
                pickContactHovered = inside
            }
        }
    }

    /// "→ Sending to <Name>" banner shown above the address field
    /// when a contact has been picked. Closes the gap where the user
    /// could only see a cryptic email/checksum address with no
    /// human-readable confirmation of who that resolves to.
    @ViewBuilder
    private func pickedContactBanner(_ contact: Contact) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            ContactAvatar(contact: contact, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Sending to")
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textTertiary)
                    Text(contact.name)
                        .font(DesignTokens.Typography.labelStrong)
                    if contact.priorSendCount >= 3 {
                        Text("✓")
                            .font(DesignTokens.Typography.micro)
                            .foregroundStyle(DesignTokens.statusCleanAccent)
                            .help("Verified — \(contact.priorSendCount) successful prior sends.")
                    }
                }
                Text(contact.address)
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: clearPickedContact) {
                Image(systemName: "xmark.circle.fill")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Clear contact — keeps the address typed so you can edit it manually.")
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.xs, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.xs))
        .background(DesignTokens.brandPrimaryWash)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    /// Drop the contact binding but keep whatever's currently in the
    /// recipient field so the user can edit it. (Matches the user
    /// typing into the address field manually — same outcome:
    /// `selectedContactId = nil`.)
    private func clearPickedContact() {
        selectedContactId = nil
    }

    private var tier: DecodedAddress? {
        decodeAddress(address: recipient)
    }

    /// Recipient's wallet class (public / dev / protocol). `nil` when
    /// the field is empty. Independent of tier decode — fires even
    /// for typo'd checksums so the chip + class-mismatch warning
    /// surface as soon as the user finishes typing the email part.
    private var recipientClass: WalletClass? {
        recipient.isEmpty ? nil : walletClass(of: recipient)
    }

    /// Active sender wallet's class, derived from `wallet.email()`.
    /// `nil` when no wallet is active (locked).
    private var senderClass: WalletClass? {
        guard let email = session.activeWallet?.email() else { return nil }
        return walletClass(ofEmail: email)
    }

    /// True iff sender and recipient are knowable and disagree on
    /// class. Protocol-address recipients (BURN / DEED / FEE / DWP)
    /// are exempt — they bypass class enforcement at the Core layer.
    private var classMismatch: Bool {
        guard let r = recipientClass, r != .protocolAddress,
              let s = senderClass else { return false }
        return r != s
    }

    private var pickedContact: Contact? {
        guard let id = selectedContactId else { return nil }
        return contactsStore.contacts.first(where: { $0.id == id })
    }

    private func pickContact(_ contact: Contact) {
        recipient = contact.address
        selectedContactId = contact.id
        if reference.isEmpty {
            reference = contact.name
        }
    }

    @ViewBuilder
    private func contactDeliveryNote(_ contact: Contact) -> some View {
        // Cheques to this contact will route to the saved delivery
        // email rather than the wallet_id's local part. Per YP §16.14.11
        // the signature still binds to receiver_wallet_id, so only
        // routing differs — the protocol state goes to the wallet_id
        // as always.
        HStack(spacing: 6) {
            Image(systemName: "envelope.arrow.triangle.branch")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.brandPrimary)
            Text("Cheques route to: \(contact.deliveryEmail)")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textSecondary)
            Spacer()
            Text("YP §16.14.11 override")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xxs, leading: DesignTokens.Spacing.xs, bottom: DesignTokens.Spacing.xxs, trailing: DesignTokens.Spacing.xs))
        .background(DesignTokens.brandPrimaryWash)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.chip))
    }

    @ViewBuilder
    private var tierBadgeRow: some View {
        if let tier {
            HStack(spacing: DesignTokens.Spacing.xs) {
                tierPill(name: tier.displayName, k: tier.k, pt: tier.proofType)
                if let rc = recipientClass {
                    WalletClassChip(cls: rc)
                }
                Text("k=\(tier.k) · \(proofTypeLabel(tier.proofType))")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textSecondary)
                Spacer()
                Text("Sender cannot override tier — the address enforces it.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
            .background(DesignTokens.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        } else {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.statusRejectedFg)
                    .font(DesignTokens.Typography.caption)
                Text("Address checksum doesn't match any known tier. Verify the recipient gave you the full address (email/<10 hex chars>).")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }
            .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
            .background(DesignTokens.statusRejectedBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        }
    }

    @ViewBuilder
    private func tierPill(name: String, k: UInt32, pt: UInt32) -> some View {
        let (fg, bg) = tierColors(name: name)
        Text(LocalizedStringKey(name))
            .font(DesignTokens.Typography.chip)
            .tracking(0.3)
            .foregroundStyle(fg)
            .padding(.horizontal, DesignTokens.Spacing.xs).padding(.vertical, 2)
            .background(bg)
            .clipShape(Capsule())
    }

    private func tierColors(name: String) -> (Color, Color) {
        let style = TierStyle(tierLabel: name)
        return (style.fg, style.bg)
    }

    private func proofTypeLabel(_ pt: UInt32) -> String {
        switch pt {
        case 0: return "ZKP"
        case 1: return "DMAP"
        case 2: return "ARK"
        default: return "?"
        }
    }

    // MARK: - Amount + schedule

    private var amountAndScheduleRow: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("AMOUNT (\(amountUnit.rawValue))")
                        .font(DesignTokens.Typography.sectionLabel)
                        .tracking(0.4)
                        .foregroundStyle(DesignTokens.textTertiary)
                    Spacer()
                    Picker("", selection: $amountUnit) {
                        ForEach(AmountUnit.allCases) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    .help("Switch between L$ (digit_version=2 display unit, 1 AXC = 100 L$) and AXC (protocol unit). Changes only how this field parses; the recipient sees the same atom amount either way.")
                }
                TextField(amountUnit == .lDollar ? "0.00" : "0.0000", text: $amountText)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.Typography.amountLarge)
                Text(amountSubtitle)
                    .font(DesignTokens.Typography.amountCaption)
                    .foregroundStyle(amountIsValid ? DesignTokens.textTertiary : DesignTokens.statusRejectedFg)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("SEND")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                TextField("Now", text: .constant("Now"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                Text("Schedule for later — coming in a follow-up.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
        }
    }

    /// Parse the amount field according to the active unit.
    /// Both multipliers track the live digit_version via the
    /// shared `lDollarAtoms()` helper / the fixed AXC scale, so
    /// the parser and formatter stay in lockstep when (eventually)
    /// the SDK starts publishing live `digit_version`. Sub-atom
    /// fractions truncate (round down).
    private var parsedAmountAtoms: UInt64? {
        let cleaned = amountText
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty,
              let dec = Decimal(string: cleaned),
              dec >= 0 else { return nil }
        let multiplier: Decimal
        switch amountUnit {
        case .lDollar: multiplier = Decimal(lDollarAtoms())     // 10^(10-N)
        case .axc:     multiplier = Decimal(10_000_000_000)     // 10^10 (invariant)
        }
        let atomsDecimal = dec * multiplier
        var rounded = Decimal()
        var src = atomsDecimal
        NSDecimalRound(&rounded, &src, 0, .down)
        return NSDecimalNumber(decimal: rounded).uint64Value
    }

    private var amountIsValid: Bool {
        guard let atoms = parsedAmountAtoms else { return false }
        let balance = session.activeWallet?.balance() ?? 0
        return atoms > 0 && atoms <= balance
    }

    private var amountSubtitle: String {
        guard let atoms = parsedAmountAtoms else {
            return amountText.isEmpty ? "" : "Couldn't parse amount."
        }
        let balance = session.activeWallet?.balance() ?? 0
        if atoms == 0 {
            return "Amount must be greater than zero."
        }
        if atoms > balance {
            return "Exceeds available balance (\(formatBalance(balance)) · \(formatAxcOnly(balance)))."
        }
        // Cross-reference: show the OTHER denomination so the user can
        // double-check before signing. Both lines are protocol-equivalent
        // (the recipient gets the same atom amount).
        switch amountUnit {
        case .lDollar: return "≈ \(formatAxcOnly(atoms))"
        case .axc:     return "≈ \(formatBalance(atoms))"
        }
    }

    // MARK: - Reference card

    private var referenceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REFERENCE")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            TextEditor(text: $reference)
                .font(DesignTokens.Typography.label)
                .frame(minHeight: 56, maxHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(DesignTokens.Spacing.xs)
                .background(DesignTokens.bgPrimary)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                        .strokeBorder(DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
                )
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        }
    }

    // MARK: - Warning copy

    private var warningCopy: some View {
        Text("Money leaves your wallet immediately at signing. Cheques cannot be cancelled. Recipient pays redemption fees.")
            .font(DesignTokens.Typography.label)
            .foregroundStyle(DesignTokens.textSecondary)
            .lineSpacing(2)
            .padding(EdgeInsets(top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.md, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.md))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Button("Cancel") {
                recipient = ""
                amountText = ""
                reference = ""
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)

            Button(signButtonLabel) {
                onSignButtonTapped()
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.brandPrimary)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(!canSign)
        }
    }

    /// Send-button dispatch. Runs (1) the Kiddo pre-flight gate so a
    /// quit-mid-session Kiddo surfaces as an explicit "Launch Kiddo?"
    /// alert instead of a silent hang; then (2) the YPX-007 §10
    /// ZKP-tier pre-flight; only then opens the SignModal.
    private func onSignButtonTapped() {
        guard let wallet = session.activeWallet else {
            showSignSheet = true
            return
        }
        kiddoGate.check(email: wallet.email()) {
            // Kiddo ready — continue with the existing dispatch.
            if let warning = wallet.checkZkpTierWarning(to: recipient) {
                tierWarning = warning
            } else {
                proceedToSign()
            }
        }
    }

    /// Gate the sign step with the L$ digit_version verify prompt for the
    /// first 3 sends after a dv change; otherwise go straight to signing.
    private func proceedToSign() {
        if digitVersion.needsSendWarning {
            showDvWarning = true
        } else {
            showSignSheet = true
        }
    }

    /// Pre-send verify prompt shown for the first 3 sends after an L$
    /// digit_version change. Shows THIS send's amount in the new and old
    /// L$ scale + the invariant AXC, so the user confirms they're sending
    /// the intended amount. Confirm → counts one (1/3 … 3/3) and proceeds
    /// to signing; after the 3rd it no longer appears.
    @ViewBuilder
    private func dvWarningSheet() -> some View {
        let atoms = parsedAmountAtoms ?? 0
        VStack(spacing: DesignTokens.Spacing.lg) {
            // Shared card: AXC on top + BEFORE → NOW L$ + explanation.
            // This send's amount is the reference amount.
            DvChangeCard(
                atoms: atoms,
                fromDV: digitVersion.fromDV,
                counter: digitVersion.sendWarningCounter,
                topLabel: "YOU ARE SENDING",
                date: digitVersion.effectiveDate
            )

            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Cancel") { showDvWarning = false }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button("Verify & continue") {
                    showDvWarning = false
                    digitVersion.consumeSendWarning()
                    showSignSheet = true
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.brandPrimary)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 460)
    }

    /// Render the YPX-007 §10.3 consent sheet. Two messages from the
    /// spec, two buttons: "Cancel" aborts; "Proceed anyway" closes the
    /// warning and opens the SignModal. The wallet is not touched and
    /// no network IO happens until the user finishes SignModal.
    @ViewBuilder
    private func zkpTierWarningSheet(warning: TierWarningRow) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.statusScarredFg)
                Text("High-security send — slower path")
                    .font(DesignTokens.Typography.bodyStrong)
            }
            Text("This transaction will be significantly slower because " +
                 "one or more of your prior witnessing validators does not " +
                 "advertise zkVM support. Forcing them to produce zkVM " +
                 "proofs may take from several seconds (GPU-equipped " +
                 "validators) to several minutes (CPU-only) per witness.")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("You may want to ask the receiver to provide a slightly " +
                 "lower-security address (e.g. their Secure address " +
                 "instead of Secure+) to avoid the latency cost.")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // Compact diagnostic row — counts from the pre-flight.
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text("ZKP-capable in prior set:")
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("\(warning.zkpCapableInPrev) / \(warning.requiredOverlap) required")
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .font(DesignTokens.Typography.monoSmall)
            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Cancel") {
                    tierWarning = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

                Button("Proceed anyway") {
                    tierWarning = nil
                    proceedToSign()
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.statusScarredFg)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.lg, leading: DesignTokens.Spacing.xl, bottom: DesignTokens.Spacing.lg, trailing: DesignTokens.Spacing.xl))
        .frame(width: 440)
    }

    private var signButtonLabel: String {
        if sendCoordinator.isSending {
            return "A send is already in progress…"
        }
        if redeemCoordinator.isRedeeming {
            return "A redeem is in progress — wait first"
        }
        if claimCoordinator.isClaiming {
            return "A genesis claim is in progress — wait first"
        }
        if session.isHibernating {
            return "Wallet hibernating — finish recovery first"
        }
        if let atoms = parsedAmountAtoms, amountIsValid {
            // Render in the user's chosen unit — they typed N L$ or N
            // AXC, so the button should echo that. Pre-fix this always
            // called formatBalance (L$-only) so flipping the unit
            // picker left the button still saying L$.
            switch amountUnit {
            case .lDollar: return "Sign and send \(formatBalance(atoms))"
            case .axc:     return "Sign and send \(formatAxcOnly(atoms))"
            }
        }
        return "Sign and send"
    }

    private var canSign: Bool {
        amountIsValid && tier != nil && session.activeWallet != nil
            && !classMismatch
            && !sendCoordinator.isSending
            && !redeemCoordinator.isRedeeming
            && !claimCoordinator.isClaiming
            && !releaseUpdate.mustUpgradeCore   // network Core rotated — see banner (YP §23.10)
            && !session.isHibernating           // YPX-020 — in-window send would reject E_WALLET_HIBERNATING
    }

    /// Cross-class TX warning — appears between the recipient card
    /// and the amount card when sender and recipient have different
    /// FACT classes. Mirrors the Core-side reject (R1) so the user
    /// sees the block at the UI layer before any network round-trip.
    private var classMismatchWarning: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(DesignTokens.statusRejectedFg)
                .font(DesignTokens.Typography.bodyStrong)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("Cross-class transaction blocked")
                    .font(DesignTokens.Typography.labelStrong)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
                Text("Sender is \(senderClass?.displayName ?? "—"); recipient is \(recipientClass?.displayName ?? "—"). The protocol prevents cross-class transactions in either direction (rule R1, AXIOM_DESIGN_FactClassIsolation.md). Send is disabled — Core would reject this transaction at validate_transaction with E_DOMAIN_MISMATCH.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .background(DesignTokens.statusRejectedBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }
}

// =================================================================
// SignModal — TX summary + wallet_key challenge + broadcast.
// =================================================================
private struct SignModal: View {
    @EnvironmentObject private var session: AppSession
    /// App-level owner of the background witness round. The modal
    /// verifies the wallet key, hands off to it, and dismisses.
    @EnvironmentObject private var coordinator: SendCoordinator
    let recipient: String
    let amountAtoms: UInt64
    /// Unit the user typed the amount in (L$ vs AXC). The sheet
    /// renders the headline amount in the same unit so the confirm
    /// step echoes the entry rather than always saying L$.
    let amountUnit: SendView.AmountUnit
    let tier: DecodedAddress?
    let reference: String
    /// YP §16.14.11 cheque delivery override. `nil` for unsaved
    /// recipients; set to the picked contact's deliveryEmail when
    /// the user selected a saved contact with an override defined.
    let deliveryEmailOverride: String?
    /// Display name of the picked contact, if any. `nil` when the
    /// user typed an address directly. Used to render the
    /// confirmation as "Send X to <Name>" with the cryptic address
    /// hidden under a Contact row, so the user can verify WHO
    /// they're sending to at the sign step (where the wallet key
    /// is about to be entered). Without this the modal showed only
    /// the address, which is hard to scan for "is this the right
    /// person?" — exactly the moment that question matters most.
    let contactName: String?
    let onCancel: () -> Void
    let onCompletion: () -> Void

    @State private var walletKey: String = ""
    @State private var status: SignStatus = .idle
    @State private var errorMessage: String? = nil
    @State private var resultTxid: String = ""
    @State private var resultBalance: UInt64 = 0
    /// Wall-clock at which `status` transitioned to `.broadcasting`.
    /// Drives both the in-flight elapsed counter and the
    /// total-elapsed display in `sentSummary`. `nil` outside the
    /// broadcast lifecycle.
    @State private var broadcastStartedAt: Date? = nil
    /// Total elapsed seconds at the moment the broadcast resolved
    /// (success or fail). Used to render `sentSummary` / failure UI
    /// without the live timer continuing to tick after the round
    /// completed.
    @State private var totalElapsedSecs: Double = 0
    /// Validator IDs (hex, `blake3(sphincs_pk)`) that witnessed the
    /// just-completed send, read from `wallet.lastReceiptWitnessIds()`
    /// after success.
    @State private var witnessNames: [String] = []
    /// "confirmed" / "pending" / "skipped" from `SendResultRow.registration`.
    @State private var registrationStatus: String = ""
    /// Parsed `code` from `FfiError.Other` on failure. Drives the
    /// actionable retry/heal button mode. `nil` for non-Other errors
    /// or non-failures.
    @State private var lastErrorCode: String? = nil
    /// Drives the optional HealModal sheet. Opened when the failure
    /// case is `PartialCommit` and the user taps the (heal-labeled)
    /// action button. On heal completion the sheet dismisses and the
    /// user can retry the send.
    @State private var showHealModal: Bool = false
    @FocusState private var keyFocused: Bool

    enum SignStatus { case idle, verifying, broadcasting, sent, failed }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("CONFIRM AND SIGN")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            Text(titleLine)
                .font(DesignTokens.Typography.amountLarge)
            if let contactName {
                // Show the full address in monospace right under the
                // headline so the user can sanity-check BOTH name and
                // address before typing their wallet key. Truncating
                // either is a recipe for confusion.
                Text(recipient)
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let _ = contactName
            }

            summaryCard

            VStack(alignment: .leading, spacing: 6) {
                Text("WALLET KEY")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                SecureField("Enter your wallet key", text: $walletKey)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyFocused)
                    .onSubmit(broadcast)
                    .disabled(status == .verifying || status == .broadcasting || status == .sent)
            }

            if status == .broadcasting {
                broadcastProgress
            }

            if status == .sent {
                sentSummary
            }

            if let errorMessage {
                failureBlock(message: errorMessage)
            }

            warningBlock

            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button(actionLabel) { primaryAction() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(walletKey.isEmpty || status == .verifying || status == .broadcasting || status == .sent)
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 480)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                keyFocused = true
            }
        }
        .sheet(isPresented: $showHealModal) {
            HealConfirmSheet(
                onCancel: { showHealModal = false },
                onCompletion: {
                    // After heal completes the user can retry the
                    // send. Clear the failure framing so the modal
                    // returns to its pre-send state.
                    showHealModal = false
                    status = .idle
                    errorMessage = nil
                    lastErrorCode = nil
                }
            )
            .environmentObject(session)
        }
    }

    /// Action-button dispatch. PartialCommit routes to the heal sheet
    /// instead of re-broadcasting (the SDK will reject the same send
    /// again until heal clears the poisoned state); every other case
    /// just retries `broadcast()`.
    ///
    /// YPX-022 (repurposed 2026-07-07): RECALL is NOT offered here — under
    /// the quorum gate a sub-quorum send is a no-op (nothing debited,
    /// nothing to reclaim), and recall now retracts a COMPLETED-but-
    /// undelivered payment via the deliberate Sent-payments surface
    /// (Settings → RECALL), never a send-failure reaction.
    private func primaryAction() {
        if status == .failed && lastErrorCode == "PartialCommit" {
            showHealModal = true
        } else {
            broadcast()
        }
    }

    private var actionLabel: String {
        switch status {
        case .idle:        return "Sign and broadcast"
        case .verifying:   return "Verifying…"
        case .broadcasting: return "Broadcasting…"
        case .sent:        return "Sent"
        case .failed:
            // Action-mode aware retry label. PartialCommit opens the
            // heal sheet directly (primaryAction dispatches);
            // everything else re-broadcasts.
            switch lastErrorCode {
            case "PartialCommit":    return "Heal wallet…"
            case "WalletBusy":       return "Wait & retry"
            default:                 return "Try again"
            }
        }
    }

    private var recipientShort: String {
        // Short the address suffix for the modal title:
        // "treasury@axiom.dev/9c24f1a832" → "treasury@axiom.dev/9c24f1…"
        guard let slash = recipient.firstIndex(of: "/") else { return recipient }
        let suffix = recipient[recipient.index(after: slash)...]
        if suffix.count > 6 {
            let head = suffix.prefix(6)
            return "\(recipient[..<slash])/\(head)…"
        }
        return recipient
    }

    /// "Send X to <Name>" when a contact is picked, else
    /// "Send X to <short-address>". The full address still appears
    /// in the body (under the headline and in the summary row).
    private var titleLine: String {
        let amount: String
        switch amountUnit {
        case .lDollar: amount = formatBalance(amountAtoms)
        case .axc:     amount = formatAxcOnly(amountAtoms)
        }
        if let contactName, !contactName.isEmpty {
            return "Send \(amount) to \(contactName)"
        }
        return "Send \(amount) to \(recipientShort)"
    }

    private var summaryCard: some View {
        VStack(spacing: 0) {
            if let contactName, !contactName.isEmpty {
                summaryRow("Contact", value: contactName)
                Divider()
            }
            summaryRow("Recipient", value: recipient, mono: true)
            Divider()
            summaryRow("Tier", value: tier.map { "\($0.displayName) · k=\($0.k)" } ?? "—")
            Divider()
            summaryRow("Amount", value: "\(formatBalance(amountAtoms))\n\(formatAxcOnly(amountAtoms))", amount: true)
            if !reference.isEmpty {
                Divider()
                summaryRow("Reference", value: reference)
            }
            Divider()
            summaryRow("Signing with", value: "Encryption verified · \(tier.map { proofLabel($0.proofType) } ?? "?") attested")
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xxs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xxs, trailing: DesignTokens.Spacing.sm))
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private func summaryRow(_ label: String, value: String, mono: Bool = false, amount: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(label))
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.textSecondary)
            Spacer()
            Text(value)
                .font(amount ? DesignTokens.Typography.amount
                      : mono ? DesignTokens.Typography.monoSmall
                      : DesignTokens.Typography.labelStrong)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.vertical, 6)
    }

    private func proofLabel(_ pt: UInt32) -> String {
        switch pt {
        case 0: return "ZKP"
        case 1: return "DMAP"
        case 2: return "ARK"
        default: return "?"
        }
    }

    private var warningBlock: some View {
        Text("By signing, you authorize \(tier.map { Int($0.k) } ?? 3) validator(s) to witness this transaction. Money leaves your wallet immediately and cheques cannot be cancelled.")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.statusScarredFg)
            .lineSpacing(2)
            .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.statusScarredBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    @ViewBuilder
    private var broadcastProgress: some View {
        // TimelineView redraws every 100ms; the wallet's
        // `send_progress()` returns the live (responded, expected_k,
        // started_at) atomic snapshot the SendMachine updates as each
        // witness response arrives. Falls back to the time-derived
        // phase hint when progress hasn't latched yet (the first
        // ~10-20ms before SendMachine's NeedNow yields).
        TimelineView(.periodic(from: Date(), by: 0.1)) { context in
            let elapsed = broadcastStartedAt.map {
                context.date.timeIntervalSince($0)
            } ?? 0
            let progress = session.activeWallet?.sendProgress()
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    if let p = progress {
                        Text("Broadcasting · \(p.responded) of \(p.expectedK) witnessed")
                            .font(DesignTokens.Typography.labelStrong)
                            .monospacedDigit()
                    } else {
                        Text("Broadcasting · k=\(tier.map { Int($0.k) } ?? 3) witnesses needed")
                            .font(DesignTokens.Typography.labelStrong)
                    }
                    Spacer()
                    Text(String(format: "%.1f s", elapsed))
                        .font(DesignTokens.Typography.mono)
                        .foregroundStyle(DesignTokens.textPrimary)
                        .monospacedDigit()
                }
                if let p = progress {
                    witnessChipStrip(responded: p.responded, k: p.expectedK)
                }
                Text(phaseHint(elapsed: elapsed, progress: progress))
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
            }
            .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.brandPrimarySoft)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        }
    }

    /// Per-witness chip strip — k cells, fills green as each validator
    /// returns. Anonymous (no validator names yet — the SDK exposes a
    /// count but not which name returned which slot); names land in
    /// `sentSummary` after success.
    private func witnessChipStrip(responded: UInt32, k: UInt32) -> some View {
        let kInt = max(1, Int(k))
        let respondedInt = min(Int(responded), kInt)
        return HStack(spacing: DesignTokens.Spacing.xxs) {
            ForEach(0..<kInt, id: \.self) { i in
                if i < respondedInt {
                    Image(systemName: "checkmark.circle.fill")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.statusCleanFg)
                } else if i == respondedInt {
                    Image(systemName: "circle.dotted")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.brandPrimary)
                } else {
                    Image(systemName: "circle")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.textTertiary)
                }
            }
        }
    }

    /// Phase hint that prefers live progress over a time-derived
    /// heuristic when the SDK has latched its counters. With live data
    /// we can be precise about "k of k witnessed → Nabla register
    /// running"; without it we fall back to the elapsed-time bands.
    private func phaseHint(elapsed: TimeInterval, progress: AppSendProgress?) -> String {
        if let p = progress {
            if p.responded < p.expectedK {
                let remaining = Int(p.expectedK) - Int(p.responded)
                return "Awaiting \(remaining) more witness\(remaining == 1 ? "" : "es"). Kiddo is relaying via SMTP; the SDK polls the inbox for each validator's cheque copy in turn."
            }
            // All k witnesses returned → Nabla register phase.
            return "All \(p.expectedK) witnesses returned. Nabla registration is running now — the FACT chain commits at registration."
        }
        let k = tier.map { Int($0.k) } ?? 3
        if elapsed < 6 {
            return "Awaiting \(k) validator witnesses. The wallet wrote the UMP request to its outbox; Kiddo is relaying via SMTP and watching the inbox for cheques."
        } else if elapsed < 30 {
            return "Witnesses in progress. If \(k) cheques arrived already, Nabla registration is running now; the FACT chain commits at registration."
        } else {
            return "Taking longer than expected. A witness or Nabla call may be hung. Check Settings → Network for any blacklisted/unresponsive validator."
        }
    }

    @ViewBuilder
    private var sentSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                Text("✓ Witness round complete")
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(DesignTokens.statusCleanFg)
                Spacer()
                Text(String(format: "%.1f s", totalElapsedSecs))
                    .font(DesignTokens.Typography.mono)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .monospacedDigit()
            }

            if !witnessNames.isEmpty {
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Text("Witnessed by:")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.textSecondary)
                    ForEach(witnessNames, id: \.self) { name in
                        Text(name)
                            .font(DesignTokens.Typography.monoSmall)
                            .foregroundStyle(DesignTokens.statusCleanAccent)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(DesignTokens.statusCleanBg)
                            .clipShape(Capsule())
                    }
                }
            }

            HStack(spacing: 6) {
                Text("New balance:")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                Text("\(formatBalance(resultBalance)) · \(formatAxcOnly(resultBalance))")
                    .font(DesignTokens.Typography.amountCaption)
            }

            HStack(spacing: 6) {
                Text("Nabla register:")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                registrationBadge
            }

            Text("txid: \(resultTxid)")
                .font(DesignTokens.Typography.monoSmall)
                .foregroundStyle(DesignTokens.textTertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusCleanBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    /// Pill rendering the Nabla register outcome — green for
    /// confirmed (clean FACT chain), amber for pending (scarred,
    /// needs heal later), grey for skipped (no Nabla configured).
    @ViewBuilder
    private var registrationBadge: some View {
        let (text, symbol, fg, bg): (String, String, Color, Color) = {
            switch registrationStatus {
            case "confirmed":
                return ("confirmed", "checkmark.seal", DesignTokens.statusCleanFg, DesignTokens.statusCleanBg)
            case "pending":
                return ("pending — heal needed", "clock", DesignTokens.statusScarredFg, DesignTokens.statusScarredBg)
            case "skipped":
                return ("skipped", "minus.circle", DesignTokens.textTertiary, DesignTokens.bgTertiary)
            default:
                return (registrationStatus.isEmpty ? "—" : registrationStatus, "questionmark.circle",
                        DesignTokens.textTertiary, DesignTokens.bgTertiary)
            }
        }()
        HStack(spacing: DesignTokens.Spacing.xxs) {
            Image(systemName: symbol)
                .font(DesignTokens.Typography.micro)
            Text(text)
                .font(DesignTokens.Typography.chip)
                .tracking(0.3)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(bg)
        .clipShape(Capsule())
    }

    private func broadcast() {
        guard let wallet = session.activeWallet else { return }
        errorMessage = nil
        lastErrorCode = nil
        status = .verifying

        // verifyWalletKey runs Argon2id (intentionally slow KDF,
        // ~0.5-2s on Apple Silicon). Must run off the main thread
        // or the cursor beachballs while the user waits.
        //
        // History: a `Task.detached` form here was *meant* to be
        // off-main but Swift's isolation-inheritance can re-pin
        // the closure to MainActor when the enclosing method is
        // implicitly MainActor (every SwiftUI view body is). The
        // explicit GCD form is unambiguous — guaranteed to land
        // on `.userInitiated` global queue regardless of the
        // call site's actor context.
        let key = walletKey
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = wallet.verifyWalletKey(walletKey: key)
            DispatchQueue.main.async {
                if !ok {
                    status = .failed
                    errorMessage = "Wrong wallet key."
                    return
                }
                handoffToCoordinator(wallet: wallet)
            }
        }
    }

    /// Post-key-verification handoff — runs on the main actor.
    /// Hands the witness round to the app-level coordinator (a
    /// detached Task that outlives this sheet) and dismisses the
    /// modal so the user drops back to the Overview to watch the
    /// top progress bar. Per CLAUDE.md §8 the SDK writes UMP to
    /// outbox/ and AxiomKiddo ships SMTP — nothing here changes
    /// that.
    @MainActor
    private func handoffToCoordinator(wallet: AxiomWallet) {
        coordinator.start(
            wallet: wallet,
            recipient: recipient,
            amountAtoms: amountAtoms,
            reference: reference,
            deliveryEmailOverride: deliveryEmailOverride
        )
        session.selectedNav = .overview
        onCompletion()
    }

    @ViewBuilder
    private func failureBlock(message: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                Text("✗ Send failed")
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
                if let code = lastErrorCode {
                    Text(code)
                        .font(DesignTokens.Typography.monoSmall)
                        .tracking(0.3)
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(DesignTokens.statusRejectedBg)
                        .clipShape(Capsule())
                }
                Spacer()
                if totalElapsedSecs > 0 {
                    Text(String(format: "%.1f s", totalElapsedSecs))
                        .font(DesignTokens.Typography.monoSmall)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .monospacedDigit()
                }
            }
            Text(actionableHint(for: lastErrorCode, fallback: message))
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusRejectedBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    /// Code → user-readable diagnosis. Falls back to the raw SDK
    /// message when the code is unknown so we never hide information.
    private func actionableHint(for code: String?, fallback: String) -> String {
        switch code {
        case "NetworkTimeout":
            return "Witness round timed out — one or more validators didn't respond in the 60-second window. Common causes: a validator's ANTIE/Lambda is unhealthy, or the carrier (Kiddo/FATMAMA) is unreachable. Retry — the SDK re-picks validators each round."
        case "PartialCommit":
            return "Partial commit detected — some validators advanced their ledger before the round aborted. The wallet is in a recoverable but inconsistent state. Run a heal pass (Settings → Wallet → Heal) before retrying."
        case "WalletBusy":
            return "Another operation is in flight on this wallet. Wait a moment and try again."
        case "MissingPrevReceipts":
            return "The wallet's last receipt is missing — Core's CL1 rejected the send. This usually means the wallet was restored without its last_receipt. Heal forward or re-fund from genesis."
        case "CoreIdMismatch":
            return "The wallet's Core ELF (axiom-core.elf) doesn't match what validators expect. Update the wallet to the version matching the live network's CoreID."
        case "SdkNotInitialized":
            return "The SDK isn't initialised — setup() failed. Check that validators.list and nabla-nodes.list are present and well-formed in ~/Library/Application Support/Axiom/."
        // Phase A pool-refusal codes — these only land here when a
        // first send post-genesis falls into the supplemental-register
        // sweep that re-runs the genesis register and trips a pool cap.
        // Primary surface for these is GenesisClaimSheet; the copy
        // here is the same.
        case "AirdropPerNablaCapsExhausted":
            if let when = Self.formattedResetTick(from: fallback) {
                return "Genesis claim limit reached on the validators we tried. Please retry after \(when)."
            }
            return "Genesis claim limit reached on the validators we tried. Please retry shortly — a per-Nabla cycle rolls every ~12 hours."
        case "AirdropMeshCapReached":
            if let when = Self.formattedResetTick(from: fallback) {
                return "The network-wide genesis-claim quota for this cycle is full. New claims accepted again at \(when)."
            }
            return "The network-wide genesis-claim quota for this cycle is full. New claims accepted when the mesh cycle resets."
        case "AirdropPoolExhausted":
            return "The Airdrop pool is fully claimed. New genesis claims are no longer available."
        case nil:
            return fallback
        default:
            return fallback
        }
    }

    /// `reset_tick` parser shared with GenesisClaimSheet. Static so the
    /// two surfaces can stay independent without round-tripping through
    /// an instance. See GenesisClaimSheet for the matching format
    /// docs — both come from `sdk/client/src/send.rs`'s pool-refusal handlers.
    static func formattedResetTick(from message: String) -> String? {
        guard let tick = parseResetTick(from: message) else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(tick))
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        fmt.locale = Locale.current
        return fmt.string(from: date)
    }

    private static func parseResetTick(from message: String) -> UInt64? {
        if let r = message.range(of: #"reset_tick=(\d+)"#, options: .regularExpression) {
            let match = message[r]
            if let eq = match.firstIndex(of: "=") {
                return UInt64(match[match.index(after: eq)...])
            }
        }
        if let r = message.range(of: #"tick (\d+) \(reset_tick\)"#,
                                  options: .regularExpression) {
            let match = message[r]
            let afterTick = match.index(match.startIndex, offsetBy: 5)
            if let sp = match[afterTick...].firstIndex(of: " ") {
                return UInt64(match[afterTick..<sp])
            }
        }
        return nil
    }
}

// =================================================================
// ContactPickerSheet — search-able contact picker for SendView.
//
// Replaces the previous inline Menu, which doesn't scale past a
// handful of contacts (no keyboard search, all rows in one column,
// no preview of the address). This sheet shows name + address +
// delivery-email indicator + prior-send badge for each contact in
// a scrollable list with a search field at the top.
// =================================================================
private struct ContactPickerSheet: View {
    let contacts: [Contact]
    let currentlyPickedId: UUID?
    let onPick: (Contact) -> Void
    let onCancel: () -> Void

    @State private var search: String = ""
    /// Row the pointer is currently over — drives the hover highlight.
    @State private var hoveredContactId: UUID? = nil
    @FocusState private var searchFocused: Bool

    private var filtered: [Contact] {
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return contacts }
        let needle = trimmed.lowercased()
        return contacts.filter {
            $0.name.lowercased().contains(needle)
                || $0.address.lowercased().contains(needle)
                || $0.notes.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            if contacts.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noMatchesState
            } else {
                contactList
            }
        }
        .frame(width: 480, height: 500)
        .onAppear {
            // Focus the search field on open so the user can type
            // immediately. The slight delay matches what LoginView
            // does for the same reason (window-activation race).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                searchFocused = true
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("PICK CONTACT")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("Send to one of your saved contacts")
                    .font(DesignTokens.Typography.heading)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.md, leading: DesignTokens.Spacing.lg, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.lg))
    }

    private var searchBar: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.textTertiary)
            TextField("Search by name, address, notes", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    // Enter selects the top match if there's exactly
                    // one — fastest path for "type a few letters,
                    // hit enter, done." If more than one match, do
                    // nothing (user picks with the mouse / arrow keys).
                    if filtered.count == 1 {
                        onPick(filtered[0])
                    }
                }
            if !search.isEmpty {
                Button(action: { search = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(DesignTokens.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.md, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.md))
    }

    @ViewBuilder
    private var contactList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { contact in
                    Button(action: { onPick(contact) }) {
                        contactRow(contact)
                    }
                    .buttonStyle(.plain)
                    .background(hoveredContactId == contact.id
                        ? DesignTokens.bgTertiary
                        : Color.clear)
                    .onHover { inside in
                        withAnimation(DesignTokens.Motion.quick()) {
                            if inside {
                                hoveredContactId = contact.id
                            } else if hoveredContactId == contact.id {
                                hoveredContactId = nil
                            }
                        }
                    }
                    Divider().opacity(0.3)
                }
            }
        }
    }

    @ViewBuilder
    private func contactRow(_ contact: Contact) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ContactAvatar(contact: contact, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(contact.name)
                        .font(DesignTokens.Typography.bodyStrong)
                        .foregroundStyle(DesignTokens.textPrimary)
                    if contact.priorSendCount >= 3 {
                        Text("✓")
                            .font(DesignTokens.Typography.micro)
                            .foregroundStyle(DesignTokens.statusCleanAccent)
                    }
                    if !contact.deliveryEmail.isEmpty {
                        Image(systemName: "envelope.arrow.triangle.branch")
                            .font(DesignTokens.Typography.micro)
                            .foregroundStyle(DesignTokens.brandPrimary)
                            .help("Has delivery email override — cheques route to \(contact.deliveryEmail).")
                    }
                }
                Text(contact.address)
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if contact.id == currentlyPickedId {
                Text("Current")
                    .font(DesignTokens.Typography.chip)
                    .tracking(0.3)
                    .foregroundStyle(DesignTokens.brandPrimary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(DesignTokens.brandPrimarySoft)
                    .clipShape(Capsule())
            } else if contact.priorSendCount > 0 {
                Text("\(contact.priorSendCount) prior")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.md, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.md))
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        Text("No contacts saved yet. Add some from the Contacts tab.")
            .font(DesignTokens.Typography.label)
            .foregroundStyle(DesignTokens.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DesignTokens.Spacing.xxl)
    }

    private var noMatchesState: some View {
        Text("No contacts match \"\(search)\".")
            .font(DesignTokens.Typography.label)
            .foregroundStyle(DesignTokens.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DesignTokens.Spacing.xxl)
    }
}

// ContactAvatar moved to ContactAvatar.swift — it now has three callers
// (ContactsView rows, the picked-contact banner, the picker rows) and takes
// the Contact itself so the initials/colour rule lives in exactly one place.
