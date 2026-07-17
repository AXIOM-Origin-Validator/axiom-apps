// swift-tools-version: 5.9
//
// UNCLE SAM — SWIFT-Aligned Messaging / Settlement Anchor Mediator.
//
// UNCLE SAM is the bank/SWIFT transport gateway in the AXIOM
// transport family (alongside ANTIE and COUSIN). It bridges the
// protocol's settlement layer to traditional banking rails,
// translating between AXIOM's internal transaction representation
// and SWIFT-aligned message formats (pacs.008 ISO 20022 primary,
// MT103 legacy fallback).
//
// Conceptually a Settlement Anchor Mediator: sits at the boundary
// between AXIOM and the banking world, mediating the handoff so
// value movements anchored inside the protocol can be expressed
// and reconciled against external SWIFT / bank settlement.
//
// Like all transport gateways UNCLE SAM performs zero cryptographic
// operations at the UI level — all crypto authority lives inside
// the AxiomSdk FFI (which in turn delegates to Core for any
// load-bearing crypto via the embedded AVM).
//
// Package shape mirrors AxiomWallet:
//   • AxiomSdk           — Swift bindings produced by uniffi-bindgen
//   • AxiomSdkFFI        — C header + module.modulemap shim
//   • UNCLESam (exec)    — the SwiftUI app, links the static
//                          libaxiom_sdk_ffi.a from target/release/

import PackageDescription

let package = Package(
    name: "UNCLESam",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "UNCLESam", targets: ["UNCLESam"]),
        // Developer tooling — Mac-side smoke that exercises the same
        // PGP envelope + CBOR + framing the SwiftUI gateway card does,
        // but from a terminal so it can be driven without the UI.
        // Not shipped in the .app bundle.
        .executable(name: "Smoke", targets: ["Smoke"]),
    ],
    targets: [
        // Swift bindings (the .swift produced by uniffi-bindgen).
        .target(
            name: "AxiomSdk",
            dependencies: ["AxiomSdkFFI"],
            path: "Generated/AxiomSdk"
        ),
        // The C header + module.modulemap that the Swift bindings
        // import from. Populated by build-dev-app.sh (uniffi-bindgen
        // output reshaped into this directory).
        .systemLibrary(
            name: "AxiomSdkFFI",
            path: "Generated/AxiomSdkFFI"
        ),
        .executableTarget(
            name: "UNCLESam",
            dependencies: ["AxiomSdk"],
            path: "Sources/UNCLESam",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                // Static-link the Rust FFI library (same .a the
                // wallet uses). Embedding the bytes in the UNCLE
                // SAM binary avoids the dylib install_name
                // portability issue on macOS.
                .unsafeFlags([
                    "../../../target/release/libaxiom_sdk_ffi.a",
                ]),
            ]
        ),
        // CLI smoke for Mac→Linux PullCheques. Mirrors
        // UncleGatewayClient logic without the SwiftUI shell so the
        // wire can be validated from a terminal.
        .executableTarget(
            name: "Smoke",
            dependencies: ["AxiomSdk"],
            path: "Sources/Smoke",
            linkerSettings: [
                .unsafeFlags([
                    "../../../target/release/libaxiom_sdk_ffi.a",
                ]),
            ]
        ),
    ]
)
