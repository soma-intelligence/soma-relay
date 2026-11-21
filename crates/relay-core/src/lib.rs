//! Soma Relay core: hybrid post-quantum identity (Ed25519 + ML-DSA-87,
//! X25519 + ML-KEM-1024), sessions, groups, channels, envelopes,
//! fragmentation and mesh routing. Pure Rust, no I/O, wasm compatible.

pub mod attachment;
pub mod card;
pub mod channel;
pub mod engine;
pub mod envelope;
pub mod error;
pub mod group;
pub mod hybrid;
pub mod mesh;
pub mod session;
pub mod util;
pub mod words;

pub use engine::{CompactJson, ContactJson, InboundJson, RelayEngine};
pub use envelope::Envelope;
pub use error::{RelayError, Result};
pub use mesh::{MeshResult, MeshRouter};

#[cfg(test)]
mod tests;
