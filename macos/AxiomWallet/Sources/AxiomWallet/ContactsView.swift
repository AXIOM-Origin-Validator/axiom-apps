import SwiftUI
import AppKit
import AxiomSdk

// =================================================================
// ContactsView — local address book.
//
// Mirrors views/06_contacts.html: header with count + "+ Add",
// search box, row table per contact (avatar with initials, name,
// address in monospace, prior-send count badge, "Send" button),
// inline detail/edit sheet.
//
// Pure client-side — contacts are stored in a JSON file in the
// app support dir, no FFI surface. The protocol has no "verified
// contact" concept; the ✓ heuristic is "≥3 successful prior sends
// to this address" per the design package (counter wiring lands
// when send-broadcast lands).
// =================================================================

struct ContactsView: View {
    // App-scoped: one ContactsStore lives in AxiomWalletApp and is
    // shared across ContactsView / SendView / ReceiveView so adds
    // here propagate instantly to Send's recipient picker.
    @EnvironmentObject private var store: ContactsStore
    @State private var search: String = ""
    @State private var editing: ContactSheetTarget? = nil

    private var filtered: [Contact] {
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return store.contacts }
        let needle = trimmed.lowercased()
        return store.contacts.filter {
            $0.name.lowercased().contains(needle)
                || $0.address.lowercased().contains(needle)
                || $0.notes.lowercased().contains(needle)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                header
                if store.contacts.isEmpty {
                    emptyState
                } else {
                    contactsTable
                }
                footnote
            }
            .padding(EdgeInsets(
                top: DesignTokens.Spacing.lg,
                leading: DesignTokens.Spacing.xl,
                bottom: DesignTokens.Spacing.lg,
                trailing: DesignTokens.Spacing.xl
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.bgPrimary)
        .sheet(item: $editing) { target in
            ContactEditSheet(
                store: store,
                existing: target.existing,
                onClose: { editing = nil }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("YOUR CONTACTS")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(headerSummary)
                    .font(DesignTokens.Typography.heading)
            }
            Spacer()
            HStack(spacing: DesignTokens.Spacing.xxs) {
                TextField("Search by name, address, notes", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                Button("+ Add") {
                    editing = ContactSheetTarget(existing: nil)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.brandPrimary)
                .controlSize(.regular)
            }
        }
    }

    private var headerSummary: String {
        let n = store.contacts.count
        return "\(n) contact\(n == 1 ? "" : "s")"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("No contacts saved yet.")
                .font(DesignTokens.Typography.labelStrong)
                .foregroundStyle(DesignTokens.textSecondary)
            Text("Contacts are stored locally on this Mac as a convenience for the Send view's recipient picker. Adding a contact does not register anything with the network — addresses already enforce their own security tier.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.sm)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    // MARK: - Table

    private var contactsTable: some View {
        VStack(spacing: 0) {
            ForEach(filtered) { contact in
                ContactRow(contact: contact) {
                    editing = ContactSheetTarget(existing: contact)
                }
                Divider().opacity(0.3)
            }
        }
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private var footnote: some View {
        Text("Contacts are saved locally on this Mac — they're a convenience for the Send view, not synced to the network. They are shared across every wallet set on this Mac (not stored inside any individual wallet), so exporting one wallet's backup file does NOT include contacts. Your own wallets (⌂) are added here automatically as you unlock them, so you can send between them without copying addresses; the wallet you're currently sending from is hidden in the Send picker, since the network rejects a send to your own address. The ✓ marker appears after 3 successful sends to the same contact. If a recipient gave you a separate email for receiving payments, save it in the optional Delivery Email field — cheques will be sent there instead of the email in the address.")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.textSecondary)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.sm)
            .background(DesignTokens.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }
}

private struct ContactSheetTarget: Identifiable {
    let existing: Contact?
    var id: String { existing?.id.uuidString ?? "__new" }
}

// =================================================================
// One contact row
// =================================================================
private struct ContactRow: View {
    let contact: Contact
    let onTap: () -> Void

    /// Hover highlight — purely visual feedback that the row is
    /// clickable; respects Reduce Motion via Motion.quick().
    @State private var isHovered: Bool = false
    /// Copy-button pulse — flips the icon to a checkmark briefly
    /// after a copy. Cleared via DispatchQueue after 1.5s.
    @State private var copied: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                avatar
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    HStack(spacing: DesignTokens.Spacing.xxs) {
                        Text(contact.name)
                            .font(DesignTokens.Typography.bodyStrong)
                        if contact.priorSendCount >= 3 {
                            Image(systemName: "checkmark.seal")
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.statusCleanAccent)
                                .help("Verified — \(contact.priorSendCount) successful prior sends.")
                                .accessibilityLabel("Verified counterparty — 3+ prior sends")
                        }
                        if contact.isOwnWallet {
                            Image(systemName: "house")
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.textTertiary)
                                .help("One of your own wallets on this Mac — added automatically.")
                                .accessibilityLabel("Your own wallet on this Mac")
                        }
                    }
                    Text(contact.address)
                        .font(DesignTokens.Typography.monoSmall)
                        .foregroundStyle(DesignTokens.textTertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                copyButton
                priorSendChip
            }
            .padding(DesignTokens.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? DesignTokens.bgTertiary : Color.clear)
        .onHover { hovering in
            withAnimation(DesignTokens.Motion.quick()) {
                isHovered = hovering
            }
        }
    }

    /// THE shared avatar (ContactAvatar.swift) — this row used to carry its own
    /// private copy of the initials rule, which is exactly how the picker kept
    /// rendering "P(" after this row was fixed. One implementation only.
    private var avatar: some View {
        ContactAvatar(contact: contact, size: 28)
    }

    /// Per-row copy affordance — mirrors the WalletsView tier-row
    /// copy button pattern (NSPasteboard.general + checkmark pulse).
    private var copyButton: some View {
        Button(action: copyAddress) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(copied ? DesignTokens.statusCleanFg : DesignTokens.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Copy address to clipboard")
    }

    private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contact.address, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }

    @ViewBuilder
    private var priorSendChip: some View {
        if contact.priorSendCount > 0 {
            Text("\(contact.priorSendCount) prior send\(contact.priorSendCount == 1 ? "" : "s")")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
        } else {
            Text("New contact")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
        }
    }
}

// =================================================================
// Add/Edit sheet
// =================================================================
private struct ContactEditSheet: View {
    @ObservedObject var store: ContactsStore
    let existing: Contact?
    let onClose: () -> Void

    @State private var name: String = ""
    @State private var address: String = ""
    @State private var deliveryEmail: String = ""
    @State private var notes: String = ""
    @State private var addressTier: DecodedAddress? = nil
    @State private var showDeleteConfirm: Bool = false

    private var isNew: Bool { existing == nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !address.trimmingCharacters(in: .whitespaces).isEmpty
            && addressTier != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(isNew ? "ADD CONTACT" : "EDIT CONTACT")
                        .font(DesignTokens.Typography.sectionLabel)
                        .tracking(0.4)
                        .foregroundStyle(DesignTokens.textTertiary)
                    Text(isNew ? "Save someone for later" : (existing?.name ?? ""))
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

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                fieldLabel("DISPLAY NAME")
                TextField("e.g. team lead, family member, supplier", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                fieldLabel("ADDRESS")
                TextField("recipient@example.com/<10 hex>", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.Typography.mono)
                    .autocorrectionDisabled()
                    .onChange(of: address) { _, new in
                        addressTier = decodeAddress(address: new)
                    }
                if !address.isEmpty {
                    if let tier = addressTier {
                        Text("Tier: \(tier.displayName) · k=\(tier.k) · \(proofTypeLabel(tier.proofType))")
                            .font(DesignTokens.Typography.micro)
                            .foregroundStyle(DesignTokens.statusCleanFg)
                    } else {
                        Text("Address checksum doesn't match any known tier.")
                            .font(DesignTokens.Typography.micro)
                            .foregroundStyle(DesignTokens.statusRejectedFg)
                    }
                }
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                fieldLabel("DELIVERY EMAIL (OPTIONAL)")
                TextField("additional email address if recipient provided one", text: $deliveryEmail)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.Typography.mono)
                    .autocorrectionDisabled()
                Text("If the recipient gave you a different email for receiving payments, put it here. Cheques to this contact will be delivered to this email instead of the one in the address. Leave blank if you weren't given an alternate email.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .lineSpacing(2)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                fieldLabel("NOTES")
                TextEditor(text: $notes)
                    .font(DesignTokens.Typography.label)
                    .frame(minHeight: 60, maxHeight: 100)
                    .scrollContentBackground(.hidden)
                    .padding(DesignTokens.Spacing.xs)
                    .background(DesignTokens.bgPrimary)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                            .strokeBorder(DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
            }

            if !isNew {
                priorSendsRow
            }

            if existing?.isOwnWallet == true {
                Text("This is one of your own wallets on this Mac. It was added automatically so you can send between your wallets without copying addresses, and its name follows the wallet set's name. It can't be deleted here — it would reappear the next time you unlock.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .lineSpacing(2)
            }

            HStack(spacing: DesignTokens.Spacing.xs) {
                if !isNew {
                    // Own-wallet rows are re-created by syncOwnWallets on every
                    // unlock, so a Delete here would look broken — the row would
                    // silently return. Blocked with the reason stated above
                    // rather than offering an action that undoes itself.
                    Button("Delete", role: .destructive) {
                        showDeleteConfirm = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(existing?.isOwnWallet == true)
                }
                Spacer()
                Button("Cancel", action: onClose)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button(isNew ? "Add" : "Save") { commit() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .disabled(!canSave)
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 460)
        .onAppear {
            if let e = existing {
                name = e.name
                address = e.address
                deliveryEmail = e.deliveryEmail
                notes = e.notes
                addressTier = decodeAddress(address: e.address)
            }
        }
        .alert("Delete \(name)?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let e = existing {
                    store.delete(e)
                    onClose()
                }
            }
        } message: {
            Text("Removes this contact from the local address book. Does not affect any wallet or network state.")
        }
    }

    private var priorSendsRow: some View {
        HStack {
            Text("PRIOR SENDS")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            Spacer()
            Text("\(existing?.priorSendCount ?? 0)")
                .font(DesignTokens.Typography.labelStrong)
            if (existing?.priorSendCount ?? 0) >= 3 {
                Text("✓ Verified")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.statusCleanAccent)
            } else {
                Text("\(3 - (existing?.priorSendCount ?? 0)) more for ✓")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
        }
    }

    private func commit() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedAddr = address.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = deliveryEmail.trimmingCharacters(in: .whitespaces)
        if let e = existing {
            var updated = e
            updated.name = trimmedName
            updated.address = trimmedAddr
            updated.deliveryEmail = trimmedEmail
            updated.notes = notes
            store.update(updated)
        } else {
            let new = Contact(name: trimmedName, address: trimmedAddr, deliveryEmail: trimmedEmail, notes: notes)
            store.add(new)
        }
        onClose()
    }

    private func proofTypeLabel(_ pt: UInt32) -> String {
        switch pt {
        case 0: return "ZKP"
        case 1: return "DMAP"
        case 2: return "ARK"
        default: return "?"
        }
    }
}

private func fieldLabel(_ text: String) -> some View {
    Text(LocalizedStringKey(text))
        .font(DesignTokens.Typography.sectionLabel)
        .tracking(0.4)
        .foregroundStyle(DesignTokens.textTertiary)
}
