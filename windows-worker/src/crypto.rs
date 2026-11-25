//! Keys derived from the pairing secret, matching `MacLink` in the Mac app.

use openssl::{base64, hash::MessageDigest, pkey::PKey, rand::rand_bytes, sign::Signer};

/// The PSK identity the Mac sends.
pub const PSK_IDENTITY: &str = "agterm-mac";
/// Characters in a secret: 32 bytes as base64url without padding.
pub const SECRET_LENGTH: usize = 43;

/// HMAC-SHA256 of `label`, keyed with the secret's UTF-8 bytes.
pub fn hmac(secret: &str, label: &str) -> Vec<u8> {
    let key = PKey::hmac(secret.as_bytes()).expect("an HMAC key from any bytes");
    let mut signer = Signer::new(MessageDigest::sha256(), &key).expect("an HMAC-SHA256 signer");
    signer.update(label.as_bytes()).expect("HMAC update");
    signer.sign_to_vec().expect("HMAC result")
}

/// The TLS pre-shared key, 32 bytes.
pub fn psk(secret: &str) -> Vec<u8> {
    hmac(secret, "agterm-mac-psk")
}

/// The gateway token the Mac sends in `auth`, 64 lowercase hex digits.
pub fn token(secret: &str) -> String {
    hmac(secret, "agterm-mac-token").iter().map(|b| format!("{b:02x}")).collect()
}

/// Whether `a` equals `b`, in time that doesn't depend on where they differ.
pub fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// A new random secret.
pub fn new_secret() -> String {
    let mut bytes = [0u8; 32];
    rand_bytes(&mut bytes).expect("random bytes from the system");
    base64url(&bytes)
}

/// Base64url without padding.
pub fn base64url(data: &[u8]) -> String {
    base64::encode_block(data).replace('+', "-").replace('/', "_").trim_end_matches('=').to_string()
}

/// Whether `secret` looks like one this worker made.
pub fn valid_secret(secret: &str) -> bool {
    secret.len() == SECRET_LENGTH && secret.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ";

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    // Vectors from `printf %s agterm-mac-psk | openssl dgst -sha256 -hmac <secret>`.
    #[test]
    fn psk_and_token_match_the_mac() {
        assert_eq!(hex(&psk(SECRET)), "7c90fec404afa69b5087c17bba8165a2ac29db8c07f26dfd506d878a7a910fb7");
        assert_eq!(token(SECRET), "dde286ed0243a8750d3f0ced001266ae3f93befd9d79de4d0ee2361acad86c7b");
    }

    #[test]
    fn new_secrets_are_valid_and_differ() {
        let (a, b) = (new_secret(), new_secret());
        assert!(valid_secret(&a) && valid_secret(&b));
        assert_ne!(a, b);
        assert!(!valid_secret("short"));
    }

    #[test]
    fn same_compares_whole_values() {
        assert!(same(b"abc", b"abc"));
        assert!(!same(b"abc", b"abd"));
        assert!(!same(b"abc", b"ab"));
    }
}
