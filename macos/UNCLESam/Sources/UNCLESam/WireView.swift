import SwiftUI

// =================================================================
// WireView — the main feature.
//
// Split-pane composer:
//   Left  → the wire form (recipient BIC, amount, ordering customer,
//           beneficiary, remittance info, etc.)
//   Right → LIVE SWIFT-aligned message preview, re-rendered on every
//           keystroke. Format toggle at the top of the preview pane:
//             • pacs.008 (ISO 20022 XML) — DEFAULT, the modern
//               standard banks are migrating to (CBPR+ / Target2 /
//               Fedwire ISO 20022 mandates).
//             • MT103 (legacy SWIFT FIN) — retained for banks still
//               operating their legacy FIN pipeline alongside the
//               ISO 20022 transition.
//           This is the centerpiece of UNCLE SAM's pitch — banks
//           see the SWIFT-aligned message they're already used to,
//           generated automatically as they compose the AXIOM
//           transaction.
//
// When the operator clicks "Send wire", the AXIOM Transaction's
// `reference` field gets the SWIFT Field-20 reference (16 chars,
// derived identically for both formats) and the full envelope body
// (chosen format) is held for UNCLE's audit DB (per
// docs/AXIOM_DESIGN_UNCLE.md §9.1). The button is a UI-only stub
// in this design preview — no protocol integration yet.
// =================================================================

/// Which SWIFT-aligned format the preview pane is rendering.
/// Default is `.pacs008` per UNCLE SAM's posture (ISO 20022 is the
/// going-forward standard); `.mt103` retained for the legacy FIN
/// pipeline.
enum WireFormat: String, CaseIterable, Identifiable {
    case pacs008 = "pacs.008"
    case mt103   = "MT103"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .pacs008: return "pacs.008 (ISO 20022 XML)"
        case .mt103:   return "MT103 (legacy SWIFT FIN)"
        }
    }
}

struct WireView: View {
    @EnvironmentObject private var session: InstitutionSession
    @EnvironmentObject private var store: MessageStore

    @State private var draft = WireDraft()
    @State private var format: WireFormat = .pacs008
    @State private var showSubmittedSheet: Bool = false
    @State private var submittedReference: String = ""
    @State private var confirmSubmit: Bool = false
    @State private var showLegend: Bool = false
    /// Inbound SWIFT → AXIOM: paste an MT103 / pacs.008 message and
    /// parse it into the composer draft (the reverse of the live
    /// preview). The other half of the bidirectional bridge.
    @State private var showImportSheet: Bool = false
    /// Per-message override for which institutional account funds
    /// this wire. nil = use the session's active account at submit
    /// time. The banker picks (Treasury / FX Desk / Branch / etc.)
    /// in the top-of-composer "Send from" panel.
    @State private var sendFromAccountId: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            sectionHeader

            HSplitView {
                composerPane
                    .frame(minWidth: 540, idealWidth: 580, maxWidth: 660)

                previewPane
                    .frame(minWidth: 480)

                if showLegend {
                    SwiftFieldLegendPanel(onDismiss: { showLegend = false })
                        .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Submit message for authorization?", isPresented: $confirmSubmit) {
            Button("Cancel", role: .cancel) {}
            Button("Submit") { submit() }
        } message: {
            Text("Reference \(referenceForSubmit) — \(draft.settlementCurrency) \(draft.settlementAmount) to \(draft.beneficiaryName). A checker (different operator) must authorize before the gateway releases it.")
        }
        .sheet(isPresented: $showSubmittedSheet) {
            SubmittedForAuthorizationSheet(
                reference: submittedReference,
                format: format,
                onGoToQueue: {
                    showSubmittedSheet = false
                    session.activeSection = .queue
                },
                onDismiss: { showSubmittedSheet = false }
            )
        }
        .sheet(isPresented: $showImportSheet) {
            ImportSwiftSheet(onParsed: { parsed in
                draft = parsed.draft
                format = parsed.format == .pacs008 ? .pacs008 : .mt103
                showImportSheet = false
            }, onDismiss: { showImportSheet = false })
        }
    }

    /// Title strip — section name + "Submit for authorization" action.
    /// Disabled when the current operator's role excludes Maker (the
    /// real maker-checker rule: only makers create messages).
    private var sectionHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("CREATE MESSAGE")
                    .font(DesignTokens.labelFont)
                    .tracking(0.6)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("Compose a customer credit transfer (ISO 20022 / SWIFT FIN)")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(DesignTokens.textPrimary)
            }
            Spacer()
            Button {
                showImportSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import SWIFT…")
                        .font(.system(size: 12))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Paste an inbound MT103 or pacs.008 message — UNCLE SAM parses it into this composer (SWIFT → AXIOM).")
            .padding(.trailing, 8)
            .disabled(!session.operatorRole.canCreate)
            Toggle(isOn: $showLegend) {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                    Text("SWIFT field-code legend")
                        .font(.system(size: 12))
                }
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Toggle plain-language explanations of the SWIFT field codes — for non-banker reviewers.")
            .padding(.trailing, 10)
            if !session.operatorRole.canCreate {
                Text("Current operator role is \(session.operatorRole.rawValue) — cannot create messages")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.statusPendingFg)
                    .padding(.trailing, 10)
            }
            Button {
                confirmSubmit = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                    Text("Submit for authorization").font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.brandNavy)
            .disabled(!isReadyToSend || !session.operatorRole.canCreate)
        }
        .padding(EdgeInsets(top: 22, leading: 28, bottom: 18, trailing: 28))
    }

    // ── Submit handling ──────────────────────────────────────

    private var referenceForSubmit: String {
        if !draft.senderReference.isEmpty { return draft.senderReference }
        switch format {
        case .pacs008: return SwiftPacs008.autoEndToEndId()
        case .mt103:   return SwiftMT103.autoReference()
        }
    }

    private func submit() {
        let ref = referenceForSubmit
        let recon = Reconciliation.summary(for: draft)
        store.submitForAuthorization(
            reference: ref,
            format: format == .pacs008 ? .pacs008 : .mt103,
            settlementCurrency: draft.settlementCurrency,
            settlementAmount: draft.settlementAmount,
            orderingCustomerName: draft.orderingCustomerName,
            beneficiaryName: draft.beneficiaryName,
            beneficiaryBIC: draft.beneficiaryInstitutionBIC,
            valueDate: draft.valueDate,
            envelopeBody: renderedEnvelope,
            reconciliationLine: recon?.line,
            reconciliationBalanced: recon?.balanced ?? true,
            maker: session.operatorName
        )
        submittedReference = ref
        // Reset draft so the next message starts fresh.
        draft = WireDraft()
        showSubmittedSheet = true
    }

    // MARK: - Left pane: composer form

    private var composerPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                composerSection(title: "SEND FROM") {
                    sendFromPicker
                }
                composerSection(title: "REFERENCE") {
                    labeledField(":20:", "Sender's reference",
                                 "auto-generated if blank",
                                 text: $draft.senderReference, mono: true,
                                 error: SwiftFieldValidation.validateReference(draft.senderReference))
                    operationCodePicker
                }
                composerSection(title: "AMOUNT") {
                    HStack(spacing: 8) {
                        labeledField(":32A: ccy", nil,  "AXC",
                                     text: $draft.settlementCurrency, mono: true,
                                     mandatory: true,
                                     error: SwiftFieldValidation.validateCurrency(draft.settlementCurrency))
                            .frame(width: 130)
                        labeledField(":32A:", "Settled amount", "0,00",
                                     text: $draft.settlementAmount, mono: true,
                                     mandatory: true,
                                     error: SwiftFieldValidation.validateAmount(draft.settlementAmount))
                    }
                    valueDatePicker
                    HStack(spacing: 8) {
                        labeledField(":33B: ccy", nil, "AXC",
                                     text: $draft.instructedCurrency, mono: true)
                            .frame(width: 130)
                        labeledField(":33B:", "Instructed amount", "0,00",
                                     text: $draft.instructedAmount, mono: true)
                    }
                    HStack(spacing: 8) {
                        labeledField(":71F:", "Sender's charges", "0,00",
                                     text: $draft.senderCharges, mono: true)
                        labeledField(":71G:", "Receiver's charges", "0,00",
                                     text: $draft.receiverCharges, mono: true)
                    }
                    HStack(spacing: 8) {
                        labeledField("Chgs ccy", nil, "AXC",
                                     text: $draft.chargesCurrency, mono: true)
                            .frame(width: 130)
                        labeledField(":36:", "Exchange rate (instructed → settled)", "0,9132",
                                     text: $draft.exchangeRate, mono: true,
                                     error: SwiftFieldValidation.validateExchangeRate(
                                        draft.exchangeRate,
                                        required: draft.instructedCurrency != draft.settlementCurrency
                                                  && !draft.instructedAmount.isEmpty))
                    }
                    chargesCodePicker
                    reconciliationLine
                }
                composerSection(title: "ORDERING CUSTOMER (:50K:)") {
                    labeledField(":50K:", "Account number",
                                 "/12345678901234567890",
                                 text: $draft.orderingCustomerAccount, mono: true)
                    labeledField(":50K:", "Name", "ACME CORPORATION LTD",
                                 text: $draft.orderingCustomerName,
                                 mandatory: true)
                    labeledTextEditor(":50K:", "Address (free-form, 3 lines × 35 chars)",
                                      text: $draft.orderingCustomerAddress)
                }
                composerSection(title: "ROUTING") {
                    counterpartyPicker
                    labeledField(":52A:", "Ordering institution BIC",
                                 session.bankBIC,
                                 text: $draft.orderingInstitutionBIC, mono: true,
                                 error: SwiftFieldValidation.validateBIC(draft.orderingInstitutionBIC))
                    HStack(spacing: 4) {
                        labeledField(":56A:", "Intermediary BIC (correspondent)",
                                     "(optional)",
                                     text: $draft.intermediaryInstitutionBIC, mono: true)
                        SwiftOnlyTag()
                    }
                    labeledField(":57A:", "Beneficiary's bank BIC",
                                 "RECVBKHKXXX",
                                 text: $draft.beneficiaryInstitutionBIC, mono: true,
                                 mandatory: true,
                                 error: SwiftFieldValidation.validateBIC(draft.beneficiaryInstitutionBIC, required: true))
                }
                composerSection(title: "BENEFICIARY (:59:)") {
                    labeledField(":59:", "Account / IBAN", "HK87654321 (or IBAN)",
                                 text: $draft.beneficiaryAccount, mono: true)
                    labeledField(":59:", "Name", "BENEFICIARY NAME LTD",
                                 text: $draft.beneficiaryName,
                                 mandatory: true)
                    labeledTextEditor(":59:", "Address",
                                      text: $draft.beneficiaryAddress)
                }
                composerSection(title: "NARRATIVE") {
                    labeledTextEditor(":70:", "Remittance information (visible to beneficiary)",
                                      text: $draft.remittanceInformation)
                    labeledTextEditor(":72:", "Sender-to-receiver info (institution-only)",
                                      text: $draft.senderToReceiverInfo)
                }
                composerSection(title: "CANCELLATION (SWIFT-ONLY)") {
                    NonCancellableBanner()
                    HStack(spacing: 4) {
                        labeledField(":MT192:", "Original wire reference being cancelled",
                                     "(blank unless cancelling)",
                                     text: $draft.cancellationReference, mono: true)
                        SwiftOnlyTag()
                    }
                }
                composerSection(title: "REGULATORY REPORTING") {
                    HStack(spacing: 8) {
                        labeledField(":77B:", "Beneficiary residency (ISO 3166-1)",
                                     "(e.g. ES)",
                                     text: $draft.beneficiaryResidency, mono: true)
                            .frame(width: 220)
                        SwiftOnlyTag()
                        Spacer()
                    }
                    HStack(spacing: 4) {
                        labeledField(":77B:", "Ultimate beneficiary (if different)",
                                     "(travel-rule data)",
                                     text: $draft.ultimateBeneficiary)
                        SwiftOnlyTag()
                    }
                    Text("These fields populate the SWIFT envelope for the bank's regulatory reporting pipeline (FATF travel rule, jurisdictional reporting). AXIOM's FACT chain does NOT carry them.")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(EdgeInsets(top: 4, leading: 28, bottom: 28, trailing: 28))
        }
    }

    // ── Counterparty picker ──────────────────────────────────
    //
    // Picking a counterparty here auto-fills the beneficiary BIC
    // + pulls the bilateral AXC ↔ fiat rate so the operator
    // doesn't retype known values. Bilateral rate flows into
    // :36: (exchange rate) + :33B: (instructed) automatically.

    // ── Send-from picker ─────────────────────────────────────
    //
    // Real banks push SWIFT messages from multiple funded
    // positions — HQ Treasury for inter-bank, FX Desk for currency
    // book, each branch for its own customer payments. This
    // picker lets the operator pick which institutional account
    // funds *this* wire. The chosen account's tier address signs
    // the AXIOM TX and its sub-BIC (if any) lands in :52A: of the
    // SWIFT envelope. Defaults to whatever the session's active
    // account is.

    @ViewBuilder
    private var sendFromPicker: some View {
        let chosen = sendFromAccountId.flatMap { id in
            session.account(id: id)
        } ?? session.activeAccount

        VStack(alignment: .leading, spacing: 6) {
            Menu {
                ForEach(session.accounts) { acct in
                    Button {
                        sendFromAccountId = acct.id
                    } label: {
                        HStack {
                            Image(systemName: acct.config.purpose.icon)
                            VStack(alignment: .leading) {
                                Text(acct.config.displayName)
                                Text(acct.config.purpose.label)
                                    .font(.system(size: 10))
                            }
                            Spacer()
                            if session.operatorRole.canViewBalance {
                                Text(acct.balanceDisplay)
                                    .font(DesignTokens.monoSmallFont)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    if let acct = chosen {
                        Image(systemName: acct.config.purpose.icon)
                            .font(.system(size: 14))
                            .foregroundStyle(DesignTokens.brandNavy)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(acct.config.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(DesignTokens.textPrimary)
                                Text("· \(acct.config.purpose.label)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DesignTokens.textSecondary)
                            }
                            HStack(spacing: 4) {
                                Text("BIC \(acct.config.effectiveBIC(fallback: session.bankBIC))")
                                    .font(DesignTokens.monoSmallFont)
                                    .foregroundStyle(DesignTokens.textTertiary)
                                if session.operatorRole.canViewBalance {
                                    Text("· float \(acct.balanceDisplay)")
                                        .font(DesignTokens.monoSmallFont)
                                        .foregroundStyle(DesignTokens.textTertiary)
                                }
                            }
                        }
                    } else {
                        Text("Pick a funding account…")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignTokens.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(DesignTokens.textTertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(DesignTokens.bgPrimary)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(DesignTokens.borderPrimary, lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            Text("AXIOM TX is signed by this account's keypair; :52A: in the SWIFT envelope carries this account's BIC. Switching here only affects this wire — the chrome-strip active account stays put.")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var counterpartyPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("COUNTERPARTY (bilateral arrangement)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
                AxiomAnchorTag()
            }
            Menu {
                Button("(none — type BIC manually)") {
                    // Don't clear typed values; just close the menu.
                }
                ForEach(CounterpartyStore.demo) { c in
                    Button("\(c.name) — \(c.bic) · 1 AXC = \(String(format: "%.4f", c.fxRate)) \(c.fxCounterCurrency)") {
                        applyCounterparty(c)
                    }
                }
            } label: {
                HStack {
                    if let active = CounterpartyStore.by(bic: draft.beneficiaryInstitutionBIC) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(active.name)
                                .font(.system(size: 12, weight: .medium))
                            Text("\(active.bic) · 1 AXC = \(String(format: "%.4f", active.fxRate)) \(active.fxCounterCurrency)")
                                .font(DesignTokens.monoSmallFont)
                                .foregroundStyle(DesignTokens.textTertiary)
                        }
                    } else {
                        Text("Select a counterparty (auto-fills BIC + bilateral FX)")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignTokens.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(DesignTokens.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(DesignTokens.bgPrimary)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(DesignTokens.borderPrimary, lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
        }
    }

    /// Apply a counterparty's bilateral arrangement to the draft.
    /// Fills BIC + chooses the bilateral FX rate and counter
    /// currency for the instructed-amount leg.
    private func applyCounterparty(_ c: Counterparty) {
        draft.beneficiaryInstitutionBIC = c.bic
        // Instructed currency = counter-currency of the bilateral
        // arrangement; rate is AXC → counter. Operator can still
        // override either field manually.
        draft.instructedCurrency = c.fxCounterCurrency
        draft.exchangeRate = String(format: "%.4f", c.fxRate)
    }

    /// Inline reconciliation line tying :32A: / :33B: / :71F: /
    /// :71G: / :36: together. The bank reviewer reads this line
    /// and immediately sees that the difference between
    /// instructed and settled is accounted for (or flags a gap).
    @ViewBuilder
    private var reconciliationLine: some View {
        if let r = Reconciliation.summary(for: draft) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: r.balanced
                          ? "checkmark.seal"
                          : "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(r.balanced
                                         ? DesignTokens.statusSettledFg
                                         : DesignTokens.statusPendingFg)
                    Text("RECONCILIATION")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(DesignTokens.textTertiary)
                }
                Text(r.line)
                    .font(DesignTokens.monoSmallFont)
                    .foregroundStyle(r.balanced
                                     ? DesignTokens.statusSettledFg
                                     : DesignTokens.statusPendingFg)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(r.balanced
                                ? DesignTokens.statusSettledBg
                                : DesignTokens.statusPendingBg)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                if let w = r.warning {
                    Text(w)
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                }
            }
        }
    }

    // MARK: - Right pane: live MT103 preview

    private var previewPane: some View {
        VStack(spacing: 0) {
            previewHeader
            ScrollView {
                Text(renderedEnvelope)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 16, leading: 22, bottom: 22, trailing: 22))
            }
            .background(DesignTokens.bgSecondary)
        }
    }

    private var previewHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LIVE \(format.rawValue.uppercased()) PREVIEW")
                        .font(DesignTokens.labelFont)
                        .tracking(0.6)
                        .foregroundStyle(DesignTokens.textTertiary)
                    Text("Updates on every keystroke")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.textSecondary)
                }
                Spacer()
                Button {
                    copyToPasteboard(renderedEnvelope)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Picker("Format", selection: $format) {
                ForEach(WireFormat.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .padding(EdgeInsets(top: 16, leading: 22, bottom: 12, trailing: 22))
        .background(DesignTokens.bgTertiary)
    }

    // MARK: - Helpers

    private var renderedEnvelope: String {
        let sender = draft.orderingInstitutionBIC.isEmpty
            ? session.bankBIC : draft.orderingInstitutionBIC
        let receiver = draft.beneficiaryInstitutionBIC.isEmpty
            ? "RECVBKHKXXX" : draft.beneficiaryInstitutionBIC
        switch format {
        case .pacs008:
            return SwiftPacs008.render(draft, senderBIC: sender, receiverBIC: receiver)
        case .mt103:
            return SwiftMT103.render(draft, senderBIC: sender, receiverBIC: receiver)
        }
    }

    private var isReadyToSend: Bool {
        // MT103 mandatory fields: 20, 23B, 32A, 50a, 59a, 71A.
        // 20 auto-fills, 23B + 71A always populated, 32A needs
        // amount, 50K + 59 need at least a name.
        let amountOK = !draft.settlementAmount.isEmpty
            && draft.settlementAmount != "0,00"
        let orderingOK = !draft.orderingCustomerName.isEmpty
        let beneficiaryOK = !draft.beneficiaryName.isEmpty
            && !draft.beneficiaryInstitutionBIC.isEmpty
        return amountOK && orderingOK && beneficiaryOK
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Building blocks

    private func composerSection<C: View>(
        title: String,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(DesignTokens.labelFont)
                .tracking(0.6)
                .foregroundStyle(DesignTokens.textTertiary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(DesignTokens.borderSecondary, lineWidth: 0.5)
            )
        }
    }

    /// Field builder with SWIFT tag prefix, optional human caption,
    /// inline validation error, mandatory marker, and a hover
    /// tooltip resolved from the SWIFT field-code legend.
    private func labeledField(_ tag: String, _ caption: String?,
                              _ placeholder: String,
                              text: Binding<String>, mono: Bool = false,
                              mandatory: Bool = false,
                              error: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(tag)
                    .font(.system(size: 10, weight: .semibold,
                                  design: .monospaced))
                    .foregroundStyle(DesignTokens.brandNavy)
                    .help(SwiftFieldLegend.tooltip(for: tag))
                if let c = caption {
                    Text(c)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DesignTokens.textTertiary)
                }
                if mandatory {
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.textTertiary)
                    Text("required")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                }
            }
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(mono ? DesignTokens.monoFont : .system(size: 13))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(error != nil
                                      ? DesignTokens.statusRejectedFg
                                      : Color.clear,
                                      lineWidth: 1)
                )
            if let err = error {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }
        }
    }

    private func labeledTextEditor(_ tag: String, _ caption: String,
                                   text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(tag)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DesignTokens.brandNavy)
                    .help(SwiftFieldLegend.tooltip(for: tag))
                Text(caption)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            TextEditor(text: text)
                .font(.system(size: 12))
                .frame(minHeight: 50, maxHeight: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(DesignTokens.borderSecondary, lineWidth: 0.5)
                )
        }
    }

    private var operationCodePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(":23B:")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DesignTokens.brandNavy)
                    .help(SwiftFieldLegend.tooltip(for: ":23B:"))
                Text("Bank operation code")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            Picker("", selection: $draft.bankOperationCode) {
                Text("CRED — Normal credit transfer").tag("CRED")
                Text("CRTS — Test").tag("CRTS")
                Text("SPAY — Standing order / scheduled").tag("SPAY")
                Text("SPRI — Priority").tag("SPRI")
                Text("SSTD — Standard").tag("SSTD")
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var chargesCodePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(":71A:")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DesignTokens.brandNavy)
                    .help(SwiftFieldLegend.tooltip(for: ":71A:"))
                Text("Charge bearer")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            Picker("", selection: $draft.chargesCode) {
                Text("OUR — Sender pays all charges").tag("OUR")
                Text("SHA — Shared").tag("SHA")
                Text("BEN — Beneficiary pays").tag("BEN")
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    /// Dual-date row. SWIFT value date is operator-editable
    /// (drives :32A:'s YYMMDD prefix); AXIOM finality is the
    /// estimated witness-quorum time, shown read-only so the
    /// operator never confuses the two timelines.
    private var valueDatePicker: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("SWIFT value date")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DesignTokens.textTertiary)
                    SwiftOnlyTag()
                }
                DatePicker("", selection: $draft.valueDate,
                           displayedComponents: .date)
                    .labelsHidden()
                Text("Used by the bank's existing pipeline; lands in :32A:")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("AXIOM finality (estimated)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DesignTokens.textTertiary)
                    AxiomAnchorTag()
                }
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.brandGold)
                    Text("≈ 3 minutes after submit")
                        .font(DesignTokens.monoSmallFont)
                        .foregroundStyle(DesignTokens.textPrimary)
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(DesignTokens.brandNavySoft)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                Text("k-witness signatures + Nabla notarisation")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            Spacer()
        }
    }
}

// =================================================================
// SubmittedForAuthorizationSheet — shown after the maker clicks
// "Submit for authorization". The message has entered the
// Pending Authorization queue; a separate checker must approve
// before the UNCLE gateway releases it.
//
// This sheet replaces the earlier "Wire ready to dispatch" demo
// confirmation — the real bank workflow has a checker gate, so
// the user-facing language now reflects that.
// =================================================================

struct SubmittedForAuthorizationSheet: View {
    let reference: String
    let format: WireFormat
    let onGoToQueue: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(DesignTokens.brandGold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Submitted for authorization")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Awaiting a second operator (checker) to authorize before release.")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.textSecondary)
                }
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Reference")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(reference)
                    .font(DesignTokens.monoFont)
                    .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTokens.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .textSelection(.enabled)
                Text(format == .pacs008
                     ? "pacs.008 envelope filed in UNCLE audit DB; reference will land in AXIOM Transaction.reference on release."
                     : "MT103 envelope filed in UNCLE audit DB; Field 20 will land in AXIOM Transaction.reference on release.")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.textTertiary)
                    .padding(.top, 2)
            }
            Divider()
            Text("Maker-checker workflow:")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.textSecondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach([
                    "1. Maker (you) drafted and submitted — DONE",
                    "2. Checker (different operator) reviews in the Pending Authorization tab",
                    "3. Checker authorizes → UNCLE gateway releases the message",
                    "4. Gateway returns ACK (or NACK on rejection)",
                    "5. Audit trail retained — regulator-queryable for 7+ years",
                ], id: \.self) { step in
                    Text(step)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.textSecondary)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button("View in queue", action: onGoToQueue)
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandNavy)
                    .controlSize(.large)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}

// =================================================================
// ImportSwiftSheet — the SWIFT → AXIOM half of the bridge. The
// operator pastes an inbound MT103 or pacs.008 message; UNCLE SAM
// detects the dialect, parses it (SwiftInboundParser) into a
// WireDraft, and loads it into the composer. The reverse of the
// live preview pane.
// =================================================================

struct ImportSwiftSheet: View {
    let onParsed: (ParsedSwiftMessage) -> Void
    let onDismiss: () -> Void

    @State private var pasted: String = ""
    @State private var detected: ParsedSwiftFormat? = nil
    @State private var warnings: [String] = []
    @State private var errorMessage: String? = nil
    @State private var parsedPreview: ParsedSwiftMessage? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 20))
                    .foregroundStyle(DesignTokens.brandNavy)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import a SWIFT message")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Paste an inbound MT103 or pacs.008 — UNCLE SAM parses it into the composer.")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.textSecondary)
                }
                Spacer()
                if let fmt = detected {
                    Text(fmt == .pacs008 ? "pacs.008 detected" : "MT103 detected")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(DesignTokens.brandNavySoft)
                        .clipShape(Capsule())
                }
            }

            TextEditor(text: $pasted)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(DesignTokens.borderSecondary, lineWidth: 0.5)
                )
                .onChange(of: pasted) { _, newValue in
                    detected = SwiftInboundParser.detectFormat(newValue)
                    errorMessage = nil
                }

            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }

            if let preview = parsedPreview {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PARSED")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(DesignTokens.textTertiary)
                    Text("\(preview.draft.settlementCurrency) \(preview.draft.settlementAmount) → \(preview.draft.beneficiaryName.isEmpty ? "(no beneficiary)" : preview.draft.beneficiaryName)")
                        .font(DesignTokens.monoSmallFont)
                        .foregroundStyle(DesignTokens.textPrimary)
                    if !preview.warnings.isEmpty {
                        ForEach(preview.warnings, id: \.self) { w in
                            Text("⚠︎ \(w)")
                                .font(.system(size: 10))
                                .foregroundStyle(DesignTokens.statusPendingFg)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onDismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button {
                    parse()
                } label: {
                    Text("Parse").frame(minWidth: 70)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(detected == nil)
                Button {
                    if let p = parsedPreview ?? attemptParse() { onParsed(p) }
                } label: {
                    Text("Load into composer").frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.brandNavy)
                .controlSize(.large)
                .disabled(detected == nil)
            }
        }
        .padding(22)
        .frame(width: 620)
    }

    private func parse() {
        if let p = attemptParse() {
            parsedPreview = p
            warnings = p.warnings
        }
    }

    private func attemptParse() -> ParsedSwiftMessage? {
        guard let p = SwiftInboundParser.parse(pasted) else {
            errorMessage = "Could not recognise this as MT103 or pacs.008. Check the message is complete."
            parsedPreview = nil
            return nil
        }
        errorMessage = nil
        return p
    }
}
