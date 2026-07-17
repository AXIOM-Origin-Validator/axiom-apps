import SwiftUI

// =================================================================
// FirstLaunchNoticeView — the one-time "this is a developer
// demonstration" notice, shown the first time the wallet opens.
//
// AXIOM Wallet is a demonstration of the protocol, not a consumer
// product: its error/warning copy is developer-facing and it cites
// the Yellow Paper throughout. A general user opening it cold would
// reasonably be confused. This sheet sets that expectation up front,
// in English / Traditional Chinese / Japanese, and is dismissed
// once — gated on a UserDefaults flag (`@AppStorage` in
// AxiomWalletApp), it never shows again.
// =================================================================
struct FirstLaunchNoticeView: View {
    /// Called when the user acknowledges. The caller persists the
    /// "seen" flag and dismisses.
    let onAcknowledge: () -> Void

    /// One language block. `points` is (bold lead, body) pairs.
    private struct NoticeSection {
        let language: String
        let title: String
        let points: [(lead: String, body: String)]
    }

    private let sections: [NoticeSection] = [
        NoticeSection(
            language: "English",
            title: "Important Notice",
            points: [
                ("This is a demonstration app.",
                 "AXIOM Wallet is built to demonstrate the AXIOM trading and transaction system. It shows how the protocol works — it is not a finished product for general use."),
                ("Messages are written for developers.",
                 "Because this is a demonstration, the warnings and error messages you see may be technical and unfriendly to general users. This is intentional — they are meant to help developers, not end users."),
                ("References point to the design documents.",
                 "In several places the app cites the AXIOM Yellow Paper or related design documents, showing where a behaviour is specified. These citations are reference material for developers, not instructions for everyday use."),
            ]
        ),
        NoticeSection(
            language: "正體中文",
            title: "重要聲明",
            points: [
                ("這是一個示範應用程式。",
                 "AXIOM 錢包旨在示範 AXIOM 的交易與轉帳系統，用以展示該協定的運作方式——它並非供一般使用的完成品。"),
                ("訊息是為開發者撰寫的。",
                 "由於這是示範版本，您所看到的警告與錯誤訊息可能較為技術性、對一般使用者並不友善。這是刻意的設計——這些訊息旨在協助開發者，而非一般使用者。"),
                ("參考說明指向設計文件。",
                 "應用程式中有多處引用 AXIOM 黃皮書（Yellow Paper）或相關設計文件，標示某項行為的規格出處。這些引用屬於開發者的參考資料，並非日常使用的操作說明。"),
            ]
        ),
        NoticeSection(
            language: "日本語",
            title: "重要なお知らせ",
            points: [
                ("これはデモ用アプリです。",
                 "AXIOM ウォレットは、AXIOM の取引・送金システムを実演するために作られています。プロトコルの動作を示すものであり、一般利用向けの完成品ではありません。"),
                ("メッセージは開発者向けです。",
                 "デモ版であるため、表示される警告やエラーメッセージは技術的で、一般のユーザーには分かりにくい場合があります。これは意図的なものであり、開発者を支援するためのものです。"),
                ("参照は設計ドキュメントを指します。",
                 "アプリ内の複数の箇所で、AXIOM イエローペーパー（Yellow Paper）や関連する設計ドキュメントが引用され、ある動作がどこで仕様化されているかが示されています。これらは開発者向けの参考資料であり、日常的な操作の手引きではありません。"),
            ]
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    ForEach(sections.indices, id: \.self) { i in
                        sectionView(sections[i])
                        if i < sections.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(DesignTokens.Spacing.lg)
            }
            Divider()
            footer
        }
        .frame(width: 540, height: 640)
        .background(DesignTokens.bgPrimary)
    }

    private var header: some View {
        VStack(spacing: DesignTokens.Spacing.xxs) {
            Text("AXIØM")
                .font(DesignTokens.Typography.bodyStrong)
                .tracking(1.0)
                .foregroundStyle(DesignTokens.brandPrimary)
            Text("Developer Demonstration")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    private func sectionView(_ s: NoticeSection) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(s.language.uppercased())
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            Text(s.title)
                .font(DesignTokens.Typography.heading)
                .foregroundStyle(DesignTokens.textPrimary)
            ForEach(s.points.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                    Text("\(i + 1).")
                        .font(DesignTokens.Typography.labelStrong)
                        .foregroundStyle(DesignTokens.textTertiary)
                        .frame(width: 16, alignment: .trailing)
                    // Bold lead sentence + regular body, one flowing
                    // paragraph via concatenated Text.
                    (Text(s.points[i].lead).font(DesignTokens.Typography.labelStrong)
                        + Text(" ")
                        + Text(s.points[i].body).font(DesignTokens.Typography.label))
                        .foregroundStyle(DesignTokens.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: onAcknowledge) {
                Text("I understand · 我明白 · 了解しました")
                    .font(DesignTokens.Typography.labelStrong)
                    .padding(.horizontal, DesignTokens.Spacing.xs)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.brandPrimary)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(DesignTokens.Spacing.md)
    }
}
