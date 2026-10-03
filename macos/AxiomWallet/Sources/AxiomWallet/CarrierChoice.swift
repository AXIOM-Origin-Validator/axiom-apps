import SwiftUI
import AxiomSdk

// ===========================================================================
// CarrierChoice — which carriers THIS APP delivers over. Per install, not per
// wallet. AXIOM_DESIGN_CarrierBoundary.md §4.2 / §4.8 (the owner, 2026-09-13).
//
// This REPLACES CarrierPreferences (per-wallet, ordered, defaulted to
// FATMAMA, pushed onto one process-global SDK slot on every wallet switch —
// KI#154). The boundary:
//
//   validator  advertises what it can serve       (email is mandatory FOR IT)
//   SDK        knows every validator's carriers   (seed ∪ hints); no default
//   app        decides what it can DELIVER, runs the transport, tells the SDK
//
// What this app can deliver is a FACT about this install: it ships exactly
// one transport — AxiomKiddo, which drains the wallet's outbox/ over SMTP.
// So the only carrier it can honestly declare is `email`. There is no
// preference to order and nothing per wallet: a keypair has no network
// position, and if TOT:7400 were firewalled here it would be firewalled for
// every wallet on this Mac.
//
// The claim-time question (CarrierQuestionCard) exists so the CHOICE is the
// user's and visible — and so a second transport can be offered without
// redesign. With one transport it has one option; it is still asked, and it
// is not pre-answered. "There is no default for the client."
//
// Stored as a comma-joined list under `carrier.delivers` via @AppStorage so
// SwiftUI re-renders on change. Declared to the SDK at launch and again right
// before the claim.
// ===========================================================================

enum CarrierChoice {
    /// Every carrier this build of the app ships a transport for. Adding a
    /// transport (a TOT drainer beside Kiddo) is: add it here, add its row to
    /// `CarrierQuestionCard`, ship the daemon. Nothing in the SDK changes.
    static let deliverable: [String] = ["email"]

    static let storageKey = "carrier.delivers"

    static var delivered: [String] {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && deliverable.contains($0) }
    }

    /// Has the user answered the question at least once?
    static var hasAnswer: Bool { !delivered.isEmpty }

    /// Push the declaration into the SDK. Called at launch (after
    /// `sdkSetup`) and right before a claim. An empty declaration is pushed
    /// as empty — the SDK then refuses to send with a message that names
    /// this screen, which is the honest state for an unanswered install.
    static func declareToSdk() {
        do {
            try sdkDeclareCarriers(carriers: delivered)
        } catch {
            NSLog("[CarrierChoice] declare failed: \(error)")
        }
    }
}

/// The claim-time question. Offers only what the app actually delivers.
struct CarrierQuestionCard: View {
    @AppStorage(CarrierChoice.storageKey) private var raw: String = ""

    private var chosen: Set<String> {
        Set(raw.split(separator: ",").map { String($0) })
    }

    private func toggle(_ scheme: String) {
        var s = chosen
        if s.contains(scheme) { s.remove(scheme) } else { s.insert(scheme) }
        raw = s.sorted().joined(separator: ",")
        CarrierChoice.declareToSdk()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("How should this wallet reach validators?")
                .font(DesignTokens.Typography.bodyStrong)
            Text("Validators publish the carriers they accept; this app ships the transports below. Pick what you will run. Nothing is chosen for you.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: Binding(get: { chosen.contains("email") }, set: { _ in toggle("email") })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Email — carried by AxiomKiddo").font(DesignTokens.Typography.label)
                    Text("Reaches every validator: each one must publish an email address (Yellow Paper §27.5.2a). Kiddo takes what this wallet writes to its outbox and sends it through your mail account.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

            if !CarrierChoice.hasAnswer {
                Text("Choose at least one carrier to claim.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.statusScarredFg)
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }
}

/// Settings card: what this app delivers, and what the SDK knows — the
/// validator table (seed ∪ hints) with each row's carriers and source.
struct CarrierBoundaryCard: View {
    @AppStorage(CarrierChoice.storageKey) private var raw: String = ""
    @State private var rows: [ValidatorTableRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            CarrierQuestionCard()

            Text("Declared to the SDK: \(CarrierChoice.delivered.isEmpty ? "nothing yet" : CarrierChoice.delivered.joined(separator: ", "))")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)

            Text("What the SDK knows — every validator's carriers, from the seed list (authoritative on identity) and from hints relayed by other validators.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(rows, id: \.validatorId) { r in
                HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                    Text(r.name).font(DesignTokens.Typography.label).frame(width: 90, alignment: .leading)
                    Text(r.source.uppercased())
                        .font(DesignTokens.Typography.chip)
                        .fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(r.source == "seed" ? DesignTokens.statusCleanBg : DesignTokens.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.chip))
                    Text(r.carriers.joined(separator: "  "))
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if rows.isEmpty {
                Text("No validators known yet.").font(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.textTertiary)
            }
        }
        .onAppear { rows = sdkValidatorTable() }
    }
}
