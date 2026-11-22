//! Smoke test of the vault surface through the UniFFI-exported functions.

use relay_ffi::{
    RelayEngine, VaultError, VaultPlain, export_min_passphrase, open_export, open_vault, prf_salt_backup,
    prf_salt_unlock, seal_export, seal_vault, unlock_check, vault_id, vault_key,
};

#[test]
fn vault_roundtrip_ffi() {
    assert_eq!(prf_salt_unlock().len(), 32);
    assert_eq!(prf_salt_backup().len(), 32);
    assert_ne!(prf_salt_unlock(), prf_salt_backup());
    assert_eq!(unlock_check(vec![1; 32]).unwrap().len(), 32);
    assert!(matches!(unlock_check(vec![1; 31]), Err(VaultError::BadKey { .. })));

    let key = vault_key(vec![2; 32]).unwrap();
    let id = vault_id(b"credential".to_vec());
    assert_eq!(id.len(), 64);
    let engine = RelayEngine::create("ffi".into());
    let plain = VaultPlain {
        engine: engine.export_state(),
        handle: Some("alice".into()),
        node_url: None,
        channels_prefs: vec![],
        photo: Some(vec![1, 2, 3]),
    };
    let blob = seal_vault(key.clone(), id.clone(), plain.clone()).unwrap();
    assert_eq!(open_vault(key.clone(), id.clone(), blob.clone()).unwrap(), plain);
    assert!(matches!(open_vault(key, vault_id(b"other".to_vec()), blob.clone()), Err(VaultError::Decrypt { .. })));
    assert_eq!(engine.sign_vault(id, blob).len(), 64);
}

#[test]
fn export_roundtrip_ffi() {
    assert_eq!(export_min_passphrase(), 10);
    let state = RelayEngine::create("ffi".into()).export_state();
    let text = seal_export("une phrase de passe".into(), state.clone());
    assert!(text.starts_with("relaystate2:"));
    assert_eq!(open_export(Some("une phrase de passe".into()), text.clone()).unwrap(), state);
    assert!(matches!(open_export(None, text.clone()), Err(VaultError::Passphrase { .. })));
    assert!(matches!(open_export(Some("autre".into()), text), Err(VaultError::Passphrase { .. })));
    assert!(matches!(open_export(None, "nope".into()), Err(VaultError::BadMagic { .. })));
}
