//! Ed25519 verification and SHA-256, both from `ring` (already required by rustls; no second crypto
//! stack). Signatures are plain Ed25519 over the exact file bytes, base64 encoded: byte-for-byte what
//! Sparkle's `sign_update -p` prints, so the ADR 0009 key signs both channels.

use base64::{engine::general_purpose::STANDARD, Engine};
use ring::{digest, signature};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CryptoError {
    BadPublicKey,
    BadSignatureEncoding,
    SignatureMismatch,
}
impl std::fmt::Display for CryptoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::BadPublicKey => "public key is not a base64 32-byte Ed25519 key",
            Self::BadSignatureEncoding => "signature is not base64 of 64 bytes",
            Self::SignatureMismatch => "signature does not match the configured public key",
        })
    }
}
impl std::error::Error for CryptoError {}

#[derive(Clone, PartialEq, Eq)]
pub struct PublicKey([u8; 32]);
impl std::fmt::Debug for PublicKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "PublicKey({})", STANDARD.encode(self.0))
    }
}
impl PublicKey {
    pub fn from_base64(text: &str) -> Result<Self, CryptoError> {
        let bytes = STANDARD
            .decode(text.trim())
            .map_err(|_| CryptoError::BadPublicKey)?;
        Ok(Self(
            bytes.try_into().map_err(|_| CryptoError::BadPublicKey)?,
        ))
    }
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }
    pub fn to_base64(&self) -> String {
        STANDARD.encode(self.0)
    }
    /// Verify `signature_b64` over exactly `message`.
    pub fn verify(&self, message: &[u8], signature_b64: &str) -> Result<(), CryptoError> {
        let sig = STANDARD
            .decode(signature_b64.trim())
            .map_err(|_| CryptoError::BadSignatureEncoding)?;
        if sig.len() != 64 {
            return Err(CryptoError::BadSignatureEncoding);
        }
        signature::UnparsedPublicKey::new(&signature::ED25519, &self.0)
            .verify(message, &sig)
            .map_err(|_| CryptoError::SignatureMismatch)
    }
}

pub struct Sha256(digest::Context);
impl Sha256 {
    pub fn new() -> Self {
        Self(digest::Context::new(&digest::SHA256))
    }
    pub fn update(&mut self, bytes: &[u8]) {
        self.0.update(bytes);
    }
    pub fn finish_hex(self) -> String {
        hex(self.0.finish().as_ref())
    }
}
impl Default for Sha256 {
    fn default() -> Self {
        Self::new()
    }
}
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(digest::digest(&digest::SHA256, bytes).as_ref())
}
fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes
        .iter()
        .fold(String::with_capacity(bytes.len() * 2), |mut s, b| {
            let _ = write!(s, "{b:02x}");
            s
        })
}
/// True for exactly 64 lowercase hex digits.
pub fn is_sha256_hex(text: &str) -> bool {
    text.len() == 64 && text.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

pub fn random_hex(bytes: usize) -> String {
    use ring::rand::{SecureRandom, SystemRandom};
    let mut buffer = vec![0u8; bytes];
    // A failing OS RNG leaves no safe token; refusing to continue is the only correct response.
    SystemRandom::new()
        .fill(&mut buffer)
        .expect("operating-system random source unavailable");
    hex(&buffer)
}

/// Fixed test keys and signing, only for tests and the feed generator's self-test. The private seeds in
/// tests are throwaway fixtures with no production meaning.
#[cfg(any(test, feature = "test-overrides"))]
pub mod testing {
    use super::*;
    use ring::signature::{Ed25519KeyPair, KeyPair};

    pub struct TestKey(Ed25519KeyPair);
    impl TestKey {
        pub fn from_seed(seed: [u8; 32]) -> Self {
            Self(Ed25519KeyPair::from_seed_unchecked(&seed).expect("32-byte seed"))
        }
        /// Fresh random 32-byte seed (for the throwaway key of the end-to-end test).
        pub fn random_seed() -> [u8; 32] {
            use ring::rand::{SecureRandom, SystemRandom};
            let mut seed = [0u8; 32];
            SystemRandom::new()
                .fill(&mut seed)
                .expect("operating-system random source unavailable");
            seed
        }
        pub fn public(&self) -> PublicKey {
            PublicKey::from_bytes(self.0.public_key().as_ref().try_into().unwrap())
        }
        pub fn sign_b64(&self, message: &[u8]) -> String {
            STANDARD.encode(self.0.sign(message).as_ref())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::testing::TestKey;
    use super::*;

    #[test]
    fn sha256_known_vector() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        let mut streaming = Sha256::new();
        streaming.update(b"a");
        streaming.update(b"bc");
        assert_eq!(streaming.finish_hex(), sha256_hex(b"abc"));
    }
    #[test]
    fn ed25519_rfc8032_test_vector_1() {
        // RFC 8032 section 7.1, TEST 1 (empty message).
        let public = PublicKey::from_bytes(hex_to_32(
            "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        ));
        let sig_hex = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b";
        let sig_bytes: Vec<u8> = (0..64)
            .map(|i| u8::from_str_radix(&sig_hex[2 * i..2 * i + 2], 16).unwrap())
            .collect();
        let sig = &STANDARD.encode(sig_bytes);
        public.verify(b"", sig).unwrap();
        assert_eq!(
            public.verify(b"x", sig),
            Err(CryptoError::SignatureMismatch)
        );
    }
    #[test]
    fn sign_verify_roundtrip_and_failures() {
        let key = TestKey::from_seed([7; 32]);
        let sig = key.sign_b64(b"feed");
        key.public().verify(b"feed", &sig).unwrap();
        assert_eq!(
            key.public().verify(b"feeD", &sig),
            Err(CryptoError::SignatureMismatch)
        );
        assert_eq!(
            key.public().verify(b"feed", "AAAA"),
            Err(CryptoError::BadSignatureEncoding)
        );
        assert_eq!(
            key.public().verify(b"feed", "!!!"),
            Err(CryptoError::BadSignatureEncoding)
        );
        let other = TestKey::from_seed([8; 32]).public();
        assert_eq!(
            other.verify(b"feed", &sig),
            Err(CryptoError::SignatureMismatch)
        );
        assert_eq!(
            PublicKey::from_base64("AAAA"),
            Err(CryptoError::BadPublicKey)
        );
        assert_eq!(
            PublicKey::from_base64(&key.public().to_base64()).unwrap(),
            key.public()
        );
    }
    fn hex_to_32(h: &str) -> [u8; 32] {
        let mut out = [0u8; 32];
        for (i, b) in out.iter_mut().enumerate() {
            *b = u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap();
        }
        out
    }
}
