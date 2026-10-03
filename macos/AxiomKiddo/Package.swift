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
        // Retention policy — what Kiddo may delete from a mail server.
        // Its own target because the decision is irreversible and must be
        // runnable in isolation; `KiddoPolicyCheck` below is that run.
        // Knows nothing of accounts, mail transport or AXIOM's protocol.
        .target(name: "KiddoPolicy", path: "Sources/KiddoPolicy"),
        .executableTarget(
            name: "AxiomKiddo",
            dependencies: ["KiddoPolicy"],
            path: "Sources/AxiomKiddo",
            // App icon ships as a resource so SwiftPM's bundle layout puts
            // it next to the binary; release-dmg.sh then copies it into
            // Contents/Resources/ where Info.plist's CFBundleIconFile
            // can find it.
            resources: [
                .copy("Resources/AppIcon.icns"),
            ]
        ),
        // The retention gate. Not a `.testTarget`: XCTest and swift-testing
        // both need a full Xcode, and this machine has CommandLineTools, so
        // `swift test` cannot build here at all. A plain executable that
        // asserts and exits non-zero works everywhere and can be wired into
        // any harness: `swift run KiddoPolicyCheck`.
        .executableTarget(
            name: "KiddoPolicyCheck",
            dependencies: ["KiddoPolicy"],
            path: "Sources/KiddoPolicyCheck"
        ),
    ]
)
