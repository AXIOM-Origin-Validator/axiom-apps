// Mirrors VERSION.toml — the canonical non-protocol version register.
// scripts/check_versions.sh fails the build if these constants drift from
// VERSION.toml. Wire / protocol versions (CORE_VERSION, AXIOM/2.11) are a
// separate axis, deliberately not here.
//
// Identity scheme (see the VERSION.toml header for the full rules): AxiomWallet
// is a PINNED client, so it ships as
//     axiomwallet-<coreid>-<app>
// where <app> is this app's own version (VERSION.toml [app] wallet) and
// <coreid> is the bundled Core's fingerprint. There is no umbrella/release
// version — the app identifies itself.
enum AxiomVersion {
    /// VERSION.toml [app] wallet — this app's own version.
    static let app = "2.23.0"

    /// VERSION.toml [workspace] crate — shared Rust crate version.
    static let crate = "3.3.0"
}
