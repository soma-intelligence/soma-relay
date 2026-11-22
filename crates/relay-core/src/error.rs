use core::fmt;

/// The single error type of the core. Every variant carries a human readable message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RelayError {
    /// A contact card or compact link failed to parse or its signature did not verify.
    InvalidCard(String),
    /// A known fingerprint presented different device keys.
    KeyChanged(String),
    /// No session, contact, group or sender key to use.
    NoSession(String),
    /// Authenticated decryption failed (tampered, replayed or wrong key).
    Decrypt(String),
    /// Bytes or JSON that do not parse.
    Malformed(String),
    /// Unknown contact, group or channel.
    Unknown(String),
    /// The exported state does not restore.
    Storage(String),
    /// A group operation was refused.
    Group(String),
}

impl RelayError {
    /// Variant name, used by the FFI and wasm wrappers.
    pub fn kind(&self) -> &'static str {
        match self {
            RelayError::InvalidCard(_) => "InvalidCard",
            RelayError::KeyChanged(_) => "KeyChanged",
            RelayError::NoSession(_) => "NoSession",
            RelayError::Decrypt(_) => "Decrypt",
            RelayError::Malformed(_) => "Malformed",
            RelayError::Unknown(_) => "Unknown",
            RelayError::Storage(_) => "Storage",
            RelayError::Group(_) => "Group",
        }
    }

    pub fn message(&self) -> &str {
        match self {
            RelayError::InvalidCard(m)
            | RelayError::KeyChanged(m)
            | RelayError::NoSession(m)
            | RelayError::Decrypt(m)
            | RelayError::Malformed(m)
            | RelayError::Unknown(m)
            | RelayError::Storage(m)
            | RelayError::Group(m) => m,
        }
    }
}

impl fmt::Display for RelayError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.kind(), self.message())
    }
}

impl std::error::Error for RelayError {}

pub type Result<T> = core::result::Result<T, RelayError>;

pub(crate) fn malformed(m: impl Into<String>) -> RelayError {
    RelayError::Malformed(m.into())
}

pub(crate) fn decrypt_err() -> RelayError {
    RelayError::Decrypt("authentication failed".into())
}

/// Errors of the passkey vault (`crate::vault`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VaultError {
    /// The blob would exceed 1 MiB even without the photo.
    TooLarge,
    /// Not a `RVB1` blob.
    BadMagic,
    /// Wrong key or vault id, or tampered bytes.
    Decrypt,
    /// The plaintext is not a `VaultPlain` this version reads.
    Parse,
}

impl VaultError {
    /// Variant name, used by the FFI and wasm wrappers.
    pub fn kind(&self) -> &'static str {
        match self {
            VaultError::TooLarge => "TooLarge",
            VaultError::BadMagic => "BadMagic",
            VaultError::Decrypt => "Decrypt",
            VaultError::Parse => "Parse",
        }
    }

    pub fn message(&self) -> &'static str {
        match self {
            VaultError::TooLarge => "vault blob larger than 1 MiB",
            VaultError::BadMagic => "not a vault blob",
            VaultError::Decrypt => "vault does not decrypt with this key",
            VaultError::Parse => "vault contents do not parse",
        }
    }
}

impl fmt::Display for VaultError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.kind(), self.message())
    }
}

impl std::error::Error for VaultError {}
