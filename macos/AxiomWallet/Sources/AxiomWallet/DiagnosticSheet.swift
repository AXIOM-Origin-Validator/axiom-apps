import SwiftUI
import AxiomSdk

// =================================================================
// DiagnosticSheet — wallet integrity check + recovery actions.
//
// Reached from Settings → Advanced or from a LoginView recovery
// link when wallet load fails. Surfaces:
//
//   - orphaned pairs.json entries pointing at missing wallet dirs
//   - unregistered wallet directories on disk
//   - stale lock files (.lock holders dead)
//   - unreadable wallet.axiom files
//   - partial pairs (Normal without Ark)
//
// Each row has a recommended action surface. Auto-fix is wired
// for the cases where a one-click remedy exists (delete stale lock,
// drop orphaned entry, reveal in Finder); others point at flows
// elsewhere in the app (Restore from backup, Recovery sheet).
// =================================================================

struct DiagnosticSheet: View {
    let onClose: () -> Void

    @State private var rows: [DiagnosticRow] = []
    @State private var statusMessages: [UUID: String] = [:]
    @State private var rowErrors: [UUID: String] = [:]
    @State private var isRunning: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    summary
                    if !rows.isEmpty {
                        ForEach(rows) { row in
                            issueCard(row)
                        }
                    } else if !isRunning {
                        cleanState
                    }
                }
                .padding(EdgeInsets(top: DesignTokens.Spacing.md,
                                    leading: DesignTokens.Spacing.lg,
                                    bottom: DesignTokens.Spacing.lg,
                                    trailing: DesignTokens.Spacing.lg))
            }
            Divider()
            footer
        }
        .frame(width: 580, height: 600)
        .onAppear { runScan() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("WALLET DIAGNOSTIC")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("Check wallet integrity")
                    .font(DesignTokens.Typography.heading)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.md,
                            leading: DesignTokens.Spacing.lg,
                            bottom: DesignTokens.Spacing.sm,
                            trailing: DesignTokens.Spacing.lg))
    }

    private var footer: some View {
        HStack {
            if isRunning {
                ProgressView().controlSize(.small)
                Text("Scanning...")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textTertiary)
            } else {
                Text("Wallets directory: \(defaultWalletDir())")
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Re-scan") { runScan() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRunning)
            Button("Done", action: onClose)
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.brandPrimary)
                .controlSize(.small)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.sm,
                            leading: DesignTokens.Spacing.lg,
                            bottom: DesignTokens.Spacing.sm,
                            trailing: DesignTokens.Spacing.lg))
    }

    private var summary: some View {
        let errorCount = rows.filter { $0.issue.severity == .error }.count
        let warningCount = rows.filter { $0.issue.severity == .warning }.count
        let infoCount = rows.filter { $0.issue.severity == .info }.count

        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                if errorCount > 0 {
                    severityChip(count: errorCount, label: "error\(errorCount == 1 ? "" : "s")", symbol: severitySymbol(.error), color: DesignTokens.statusRejectedFg, bg: DesignTokens.statusRejectedBg)
                }
                if warningCount > 0 {
                    severityChip(count: warningCount, label: "warning\(warningCount == 1 ? "" : "s")", symbol: severitySymbol(.warning), color: DesignTokens.statusScarredFg, bg: DesignTokens.statusScarredBg)
                }
                if infoCount > 0 {
                    severityChip(count: infoCount, label: "informational", symbol: severitySymbol(.info), color: DesignTokens.textSecondary, bg: DesignTokens.bgTertiary)
                }
                Spacer()
            }
            Text("Pure on-disk checks. No FFI mutation; auto-fixes are explicit per-row clicks.")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
                .padding(.top, DesignTokens.Spacing.xxs)
        }
    }

    private func severityChip(count: Int, label: String, symbol: String, color: Color, bg: Color) -> some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            Image(systemName: symbol)
                .font(DesignTokens.Typography.micro)
            Text("\(count)")
                .font(DesignTokens.Typography.labelStrong)
            Text(LocalizedStringKey(label))
                .font(DesignTokens.Typography.micro)
        }
        .foregroundStyle(color)
        .padding(.horizontal, DesignTokens.Spacing.xs).padding(.vertical, 3)
        .background(bg)
        .clipShape(Capsule())
    }

    private var cleanState: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DesignTokens.statusCleanFg)
                Text("All checks passed")
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(DesignTokens.statusCleanFg)
            }
            Text("No orphaned wallet sets, no stale locks, no unreadable wallet files. The wallets directory is in a consistent state.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.sm,
                            leading: DesignTokens.Spacing.sm,
                            bottom: DesignTokens.Spacing.sm,
                            trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusCleanBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private func issueCard(_ row: DiagnosticRow) -> some View {
        let issue = row.issue
        let color: Color = {
            switch issue.severity {
            case .error:   return DesignTokens.statusRejectedFg
            case .warning: return DesignTokens.statusScarredFg
            case .info:    return DesignTokens.textSecondary
            }
        }()
        let bg: Color = {
            switch issue.severity {
            case .error:   return DesignTokens.statusRejectedBgSoft
            case .warning: return DesignTokens.statusScarredBgSoft
            case .info:    return DesignTokens.bgTertiary
            }
        }()

        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack {
                Text(issue.title)
                    .font(DesignTokens.Typography.labelStrong)
                    .foregroundStyle(color)
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: severitySymbol(issue.severity))
                        .font(DesignTokens.Typography.micro)
                    Text(severityLabel(issue.severity))
                        .font(DesignTokens.Typography.chip)
                        .tracking(0.3)
                }
                .foregroundStyle(color)
                .accessibilityElement(children: .combine)
            }
            Text(issue.detail)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
            if let action = issue.suggestedAction {
                HStack {
                    Spacer()
                    Button(action) { applyFix(row) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if let msg = statusMessages[row.id] {
                Text("✓ \(msg)")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.statusCleanFg)
            }
            if let err = rowErrors[row.id] {
                Text("✗ \(err)")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs,
                            leading: DesignTokens.Spacing.sm,
                            bottom: DesignTokens.Spacing.xs,
                            trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private func severityLabel(_ s: DiagnosticSeverity) -> String {
        switch s {
        case .error:   return "ERROR"
        case .warning: return "WARNING"
        case .info:    return "INFO"
        }
    }

    /// SF Symbol per severity — severities are never color-only.
    private func severitySymbol(_ s: DiagnosticSeverity) -> String {
        switch s {
        case .error:   return "xmark.octagon"
        case .warning: return "exclamationmark.triangle"
        case .info:    return "info.circle"
        }
    }

    // MARK: - Actions

    private func runScan() {
        isRunning = true
        rows = []
        statusMessages = [:]
        rowErrors = [:]
        Task { @MainActor in
            let results = runWalletDiagnostic(parentDir: defaultWalletDir())
            rows = results
            isRunning = false
        }
    }

    private func applyFix(_ row: DiagnosticRow) {
        let id = row.id
        rowErrors.removeValue(forKey: id)
        Task { @MainActor in
            do {
                let msg = try applyDiagnosticFix(row.issue, parentDir: defaultWalletDir())
                if !msg.isEmpty {
                    statusMessages[id] = msg
                }
                // Re-scan after a fix so the row goes away.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    runScan()
                }
            } catch {
                rowErrors[id] = error.localizedDescription
            }
        }
    }
}
