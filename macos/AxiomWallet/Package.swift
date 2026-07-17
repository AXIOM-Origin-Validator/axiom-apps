// swift-tools-version: 5.9
//
// AxiomWallet — macOS native wallet app.
//
// Layered as Swift Package + the AxiomSdk binary target wrapping the
// Rust SDK FFI. Xcode opens this directory directly. `build.sh`
// produces the static library + reshapes the uniffi-bindgen output
// into Generated/AxiomSdk/ + Generated/AxiomSdkFFI/.

import PackageDescription

let package = Package(
    name: "AxiomWallet",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AxiomWallet", targets: ["AxiomWallet"]),
        .executable(name: "SmokeTest", targets: ["SmokeTest"]),
    ],
    targets: [
        // Swift bindings (the .swift produced by uniffi-bindgen).
        .target(
            name: "AxiomSdk",
            dependencies: ["AxiomSdkFFI"],
            path: "Generated/AxiomSdk"
        ),
        // The C header + module.modulemap that the Swift bindings
        // import from. `build.sh` populates this directory.
        .systemLibrary(
            name: "AxiomSdkFFI",
            path: "Generated/AxiomSdkFFI"
        ),
        .executableTarget(
            name: "AxiomWallet",
            dependencies: ["AxiomSdk"],
            path: "Sources/AxiomWallet",
            // Localization resources. `defaultLocalization` on the
            // package is "en" — every `Text("...")` literal in
            // SwiftUI is auto-treated as a LocalizedStringKey and
            // resolved against the bundled .strings files. Adding a
            // new language is `Sources/AxiomWallet/Resources/<lang>.lproj/Localizable.strings`.
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                // Link the Rust **static** library produced by
                // `cargo build -p axiom-sdk-ffi --release`.
                //
                // We pass the `.a` by explicit path rather than
                // `-laxiom_sdk_ffi`: on macOS the linker picks
                // `.dylib` over `.a` when both are findable on the
                // `-L` path, and the dylib's install_name is the
                // absolute path from THIS build machine — that
                // path doesn't exist on a user's Mac and dyld
                // refuses to launch with "Library not loaded".
                //
                // Static linking embeds the FFI bytes inside the
                // wallet binary; no external library to ship,
                // no install_name issue, runs portably.
                .unsafeFlags([
                    "../../../target/release/libaxiom_sdk_ffi.a",
                ]),
            ]
        ),
        // Headless smoke test: same FFI surface as LoginView, no GUI.
        // Run via `swift run SmokeTest`.
        .executableTarget(
            name: "SmokeTest",
            dependencies: ["AxiomSdk"],
            path: "Sources/SmokeTest",
            linkerSettings: [
                .unsafeFlags([
                    "-L", "../../../target/release",
                    "-laxiom_sdk_ffi",
                ]),
            ]
        ),
    ]
)
