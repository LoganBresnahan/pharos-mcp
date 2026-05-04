//// HTTP client for the optional `pharos_ext` VSCode extension.
////
//// On startup, probes `http://127.0.0.1:<port>/healthz` (port from
//// `~/.config/pharos/bridge-port` or `PHAROS_BRIDGE_PORT`).
//// If the extension responds and bridge protocol versions match,
//// bridge mode activates. Otherwise the binary runs disk-only.
////
//// All requests carry `X-Bridge-Protocol-Version: <ver>`. See
//// `doc/bridge-protocol.md` for the endpoint spec.
////
//// Stub — probe + GET helpers land in Milestone 7.

/// Placeholder so Gleam does not flag this as an empty module.
/// Removed in the milestone that implements this module.
pub const placeholder: Nil = Nil
