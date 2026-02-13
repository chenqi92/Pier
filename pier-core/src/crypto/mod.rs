/// Crypto utilities for secure credential handling.
/// In practice, macOS Keychain is used via Swift for most credential storage.
/// This module provides additional encryption helpers.

use ring::aead;
use ring::rand::{SecureRandom, SystemRandom};

/// Encrypt data using AES-256-GCM.
pub fn encrypt(key: &[u8; 32], plaintext: &[u8]) -> Result<Vec<u8>, anyhow::Error> {
    let rng = SystemRandom::new();
    let unbound_key = aead::UnboundKey::new(&aead::AES_256_GCM, key)
        .map_err(|_| anyhow::anyhow!("Invalid key"))?;
    let sealing_key = aead::LessSafeKey::new(unbound_key);

    let mut nonce_bytes = [0u8; 12];
    rng.fill(&mut nonce_bytes)
        .map_err(|_| anyhow::anyhow!("RNG failed"))?;
    let nonce = aead::Nonce::assume_unique_for_key(nonce_bytes);

    let mut in_out = plaintext.to_vec();
    sealing_key
        .seal_in_place_append_tag(nonce, aead::Aad::empty(), &mut in_out)
        .map_err(|_| anyhow::anyhow!("Encryption failed"))?;

    // Prepend nonce to ciphertext
    let mut result = nonce_bytes.to_vec();
    result.extend(in_out);
    Ok(result)
}

/// Decrypt AES-256-GCM encrypted data.
pub fn decrypt(key: &[u8; 32], ciphertext: &[u8]) -> Result<Vec<u8>, anyhow::Error> {
    if ciphertext.len() < 12 {
        return Err(anyhow::anyhow!("Ciphertext too short"));
    }

    let (nonce_bytes, encrypted) = ciphertext.split_at(12);
    let nonce_bytes: [u8; 12] = nonce_bytes.try_into()?;
    let nonce = aead::Nonce::assume_unique_for_key(nonce_bytes);

    let unbound_key = aead::UnboundKey::new(&aead::AES_256_GCM, key)
        .map_err(|_| anyhow::anyhow!("Invalid key"))?;
    let opening_key = aead::LessSafeKey::new(unbound_key);

    let mut in_out = encrypted.to_vec();
    let plaintext = opening_key
        .open_in_place(nonce, aead::Aad::empty(), &mut in_out)
        .map_err(|_| anyhow::anyhow!("Decryption failed"))?;

    Ok(plaintext.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let key = [0x42u8; 32];
        let plaintext = b"Hello, Pier Terminal!";

        let encrypted = encrypt(&key, plaintext).unwrap();
        assert_ne!(&encrypted, plaintext);

        let decrypted = decrypt(&key, &encrypted).unwrap();
        assert_eq!(&decrypted, plaintext);
    }

    #[test]
    fn test_decrypt_invalid() {
        let key = [0x42u8; 32];
        let result = decrypt(&key, b"short");
        assert!(result.is_err());
    }
}
