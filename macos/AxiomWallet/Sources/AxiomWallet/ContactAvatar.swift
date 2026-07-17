import SwiftUI

// =================================================================
// ContactAvatar — the circular initials avatar for a Contact.
//
// THE single implementation. Three callers: ContactsView's list rows,
// SendView's picked-contact banner, and ContactPickerSheet's rows.
//
// It lived inline in SendView.swift with a note to extract it "if a
// third caller appears" — but ContactsView never adopted it and grew a
// private copy of the same logic instead, so the two drifted: the "P("
// initials bug was fixed in ContactsView's copy and stayed live in the
// picker. Hence one type, taking the Contact itself rather than a bare
// name, so no caller can re-derive the rule differently. Do not add a
// second avatar — extend this one.
// =================================================================

struct ContactAvatar: View {
    let contact: Contact
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
                .frame(width: size, height: size)
            Text(initials)
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(foreground)
        }
        .help(helpText)
    }

    /// An own wallet carries its MODE in the avatar colour, using the same
    /// mapping as WalletsView's per-wallet tag chips — Normal = brand red,
    /// Ark = neutral. Keeping the two screens' colour language identical
    /// matters more than making Ark "pop": the same wallet must not read red
    /// in one pane and grey in another. Counterparties stay neutral.
    private var fill: Color {
        isOwnNormal ? DesignTokens.brandPrimary : DesignTokens.bgTertiary
    }

    private var foreground: Color {
        isOwnNormal ? .white : DesignTokens.textSecondary
    }

    private var isOwnNormal: Bool { contact.isOwnWallet && !contact.ownWalletIsArk }

    private var helpText: String {
        guard contact.isOwnWallet else { return "" }
        return contact.ownWalletIsArk
            ? "Your Ark wallet — offline mode."
            : "Your Normal wallet — online modes."
    }

    private var initials: String {
        // Own rows are titled "<pair> (Normal)" / "<pair> (Ark)". Taking the
        // first letter of each of the first two words rendered "Personal (Ark)"
        // as "P(" — it read the opening paren as an initial. The mode rides the
        // colour, so the letter is the PAIR's alone: both modes give "P".
        if contact.isOwnWallet {
            let pair = contact.name.components(separatedBy: " (").first ?? contact.name
            return String(pair.prefix(1)).uppercased()
        }
        // Counterparties: initials of the first two words, skipping any that
        // don't start with a letter or number — the same paren trap otherwise
        // turns "Bob (work)" into "B(".
        let words = contact.name
            .split(separator: " ")
            .filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        if words.count >= 2 {
            return words.prefix(2).map { String($0.prefix(1)) }.joined().uppercased()
        }
        if let only = words.first {
            return String(only.prefix(2)).uppercased()
        }
        return String(contact.name.prefix(2)).uppercased()
    }
}
