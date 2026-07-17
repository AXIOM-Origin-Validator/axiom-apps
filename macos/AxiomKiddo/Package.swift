// swift-tools-version: 5.9
//
// AxiomKiddo — macOS mail-shaped gateway for AXIOM wallets.
//
// Watches each configured wallet's outbox/ for outbound UMP envelopes,
// ships them via SMTP. Polls POP3 (or other inbound) for incoming
// cheques, drops them into the wallet's inbox/. Per CLAUDE.md §8 and
// docs/AXIOM_DESIGN_MacOSReferenceApps.md, this app NEVER touches
// wallet CBOR — it's a pure mail-envelope transport.
//
// No FFI dependency. Kiddo doesn't know the AXIOM protocol.

import PackageDescription

let package = Package(
    name: "AxiomKiddo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AxiomKiddo", targets: ["AxiomKiddo"]),
    ],
    targets: [
        .executableTarget(
            name: "AxiomKiddo",
            path: "Sources/AxiomKiddo",
            // App icon ships as a resource so SwiftPM's bundle layout puts
            // it next to the binary; release-dmg.sh then copies it into
            // Contents/Resources/ where Info.plist's CFBundleIconFile
            // can find it.
            resources: [
                .copy("Resources/AppIcon.icns"),
            ]
        ),
    ]
)
