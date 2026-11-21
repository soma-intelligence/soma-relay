//! Hybrid primitives: Ed25519 + ML-DSA-87 signatures, X25519 and ML-KEM-1024.
//!
//! Secret keys are stored as seeds (32 B for the signature keys, 64 B for ML-KEM)
//! and expanded on use, which keeps the exported state small.

use ed25519_dalek::{Signer, SigningKey, VerifyingKey};
use libcrux_ml_dsa::ml_dsa_87;
use libcrux_ml_kem::mlkem1024;
use serde::{Deserialize, Serialize};
use x25519_dalek::{PublicKey as XPub, StaticSecret};
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use crate::error::{RelayError, Result};
use crate::util::Rng;

pub const MLDSA_PUB_LEN: usize = 2592;
pub const MLDSA_SIG_LEN: usize = 4627;
pub const MLKEM_PUB_LEN: usize = 1568;
pub const MLKEM_CT_LEN: usize = 1568;

/// ML-DSA context string (domain separation of every hybrid signature).
const DSA_CONTEXT: &[u8] = b"soma-relay/v1";

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq, Debug)]
pub struct HybridSig {
    pub ed: Vec<u8>,
    pub dsa: Vec<u8>,
}

/// Identity signing key (Ed25519 + ML-DSA-87), as seeds.
#[derive(Clone, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
pub struct SigningSeeds {
    pub ed: [u8; 32],
    pub dsa: [u8; 32],
}

impl SigningSeeds {
    pub fn generate(rng: &mut Rng) -> Self {
        SigningSeeds { ed: rng.bytes(), dsa: rng.bytes() }
    }

    pub fn ed_public(&self) -> [u8; 32] {
        SigningKey::from_bytes(&self.ed).verifying_key().to_bytes()
    }

    pub fn dsa_public(&self) -> Vec<u8> {
        let kp = ml_dsa_87::generate_key_pair(self.dsa);
        kp.verification_key.as_slice().to_vec()
    }

    pub fn ed_sign(&self, msg: &[u8]) -> [u8; 64] {
        SigningKey::from_bytes(&self.ed).sign(msg).to_bytes()
    }

    pub fn sign(&self, msg: &[u8], rng: &mut Rng) -> HybridSig {
        let ed = self.ed_sign(msg).to_vec();
        let kp = ml_dsa_87::generate_key_pair(self.dsa);
        let mut sk = kp.signing_key;
        let sig = ml_dsa_87::sign(&sk, msg, DSA_CONTEXT, rng.bytes())
            .expect("ML-DSA signing with a valid key and short context");
        sk.as_ref_mut().zeroize();
        HybridSig { ed, dsa: sig.as_slice().to_vec() }
    }
}

pub fn ed_verify(public: &[u8; 32], msg: &[u8], sig: &[u8]) -> bool {
    let Ok(vk) = VerifyingKey::from_bytes(public) else { return false };
    let Ok(sig) = <[u8; 64]>::try_from(sig) else { return false };
    vk.verify_strict(msg, &ed25519_dalek::Signature::from_bytes(&sig)).is_ok()
}

/// Verifies both halves; true only if both verify.
pub fn hybrid_verify(ed_pub: &[u8; 32], dsa_pub: &[u8], msg: &[u8], sig: &HybridSig) -> bool {
    if !ed_verify(ed_pub, msg, &sig.ed) {
        return false;
    }
    let Ok(vk) = <[u8; MLDSA_PUB_LEN]>::try_from(dsa_pub) else { return false };
    let Ok(s) = <[u8; MLDSA_SIG_LEN]>::try_from(sig.dsa.as_slice()) else { return false };
    let vk = ml_dsa_87::MLDSA87VerificationKey::new(vk);
    let s = ml_dsa_87::MLDSA87Signature::new(s);
    ml_dsa_87::verify(&vk, msg, DSA_CONTEXT, &s).is_ok()
}

/// X25519 key pair stored as its secret scalar.
#[derive(Clone, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
pub struct XKey {
    pub secret: [u8; 32],
}

impl XKey {
    pub fn generate(rng: &mut Rng) -> Self {
        XKey { secret: rng.bytes() }
    }

    pub fn public(&self) -> [u8; 32] {
        XPub::from(&StaticSecret::from(self.secret)).to_bytes()
    }

    /// X25519; rejects an all-zero (non-contributory) result.
    pub fn dh(&self, peer: &[u8; 32]) -> Result<Zeroizing<[u8; 32]>> {
        let out = StaticSecret::from(self.secret).diffie_hellman(&XPub::from(*peer));
        if !out.was_contributory() {
            return Err(RelayError::Decrypt("low order X25519 point".into()));
        }
        Ok(Zeroizing::new(out.to_bytes()))
    }
}

/// ML-KEM-1024 key pair stored as its 64-byte seed.
#[derive(Clone, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
pub struct KemKey {
    pub seed: Vec<u8>,
}

impl KemKey {
    pub fn generate(rng: &mut Rng) -> Self {
        let s: [u8; 64] = rng.bytes();
        KemKey { seed: s.to_vec() }
    }

    fn seed_array(&self) -> [u8; 64] {
        let mut s = [0u8; 64];
        let n = self.seed.len().min(64);
        s[..n].copy_from_slice(&self.seed[..n]);
        s
    }

    pub fn public(&self) -> Vec<u8> {
        let mut seed = self.seed_array();
        let kp = mlkem1024::generate_key_pair(seed);
        seed.zeroize();
        kp.public_key().as_slice().to_vec()
    }

    pub fn decapsulate(&self, ct: &[u8]) -> Result<Zeroizing<[u8; 32]>> {
        let ct: [u8; MLKEM_CT_LEN] =
            ct.try_into().map_err(|_| RelayError::Malformed("bad ML-KEM ciphertext length".into()))?;
        let mut seed = self.seed_array();
        let kp = mlkem1024::generate_key_pair(seed);
        seed.zeroize();
        let ss = mlkem1024::decapsulate(kp.private_key(), &mlkem1024::MlKem1024Ciphertext::from(ct));
        Ok(Zeroizing::new(ss))
    }
}

/// Encapsulates to a peer ML-KEM-1024 public key (validated first).
pub fn kem_encapsulate(public: &[u8], rng: &mut Rng) -> Result<(Vec<u8>, Zeroizing<[u8; 32]>)> {
    let pk: [u8; MLKEM_PUB_LEN] =
        public.try_into().map_err(|_| RelayError::Malformed("bad ML-KEM public key length".into()))?;
    let pk = mlkem1024::MlKem1024PublicKey::from(pk);
    if !mlkem1024::validate_public_key(&pk) {
        return Err(RelayError::Malformed("invalid ML-KEM public key".into()));
    }
    let (ct, ss) = mlkem1024::encapsulate(&pk, rng.bytes());
    Ok((ct.as_slice().to_vec(), Zeroizing::new(ss)))
}

pub fn valid_kem_public(public: &[u8]) -> bool {
    let Ok(pk) = <[u8; MLKEM_PUB_LEN]>::try_from(public) else { return false };
    mlkem1024::validate_public_key(&mlkem1024::MlKem1024PublicKey::from(pk))
}
