//! `wasm-pack test --node crates/relay-wasm`: vault roundtrip through the JS surface.
#![cfg(target_arch = "wasm32")]

use js_sys::{Object, Reflect, Uint8Array};
use relay_wasm::{
    WasmRelayEngine, open_export, open_vault, prf_salt_backup, prf_salt_unlock, seal_export, seal_vault, unlock_check,
    vault_id, vault_key,
};
use wasm_bindgen::{JsCast, JsValue};
use wasm_bindgen_test::wasm_bindgen_test;

fn set(o: &Object, k: &str, v: &JsValue) {
    Reflect::set(o, &k.into(), v).unwrap();
}

fn bytes(o: &JsValue, k: &str) -> Vec<u8> {
    Reflect::get(o, &k.into()).unwrap().dyn_into::<Uint8Array>().unwrap().to_vec()
}

#[wasm_bindgen_test]
fn vault_roundtrip_wasm() {
    assert_eq!(prf_salt_unlock().len(), 32);
    assert_ne!(prf_salt_unlock(), prf_salt_backup());
    assert_eq!(unlock_check(&[1; 32]).unwrap().len(), 32);
    assert!(unlock_check(&[1; 31]).is_err());
    let key = vault_key(&[2; 32]).unwrap();
    let id = vault_id(b"credential");
    let engine = WasmRelayEngine::create("web".into());
    let plain = Object::new();
    set(&plain, "v", &JsValue::from(9)); // ignored: sealVault writes the current version
    set(&plain, "engine", &Uint8Array::from(engine.export_state().as_slice()));
    set(&plain, "handle", &JsValue::from("alice"));
    set(&plain, "nodeUrl", &JsValue::NULL);
    set(&plain, "channelsPrefs", &Uint8Array::from(&b"{}"[..]));
    set(&plain, "photo", &Uint8Array::from(&[1u8, 2, 3][..]));
    let blob = seal_vault(&key, id.clone(), plain.into()).unwrap();
    let opened: JsValue = open_vault(&key, id.clone(), &blob).unwrap().into();
    assert_eq!(bytes(&opened, "engine"), engine.export_state());
    assert_eq!(bytes(&opened, "photo"), vec![1, 2, 3]);
    assert_eq!(Reflect::get(&opened, &"handle".into()).unwrap().as_string().as_deref(), Some("alice"));
    assert!(Reflect::get(&opened, &"nodeUrl".into()).unwrap().is_null());
    let e = open_vault(&key, vault_id(b"other"), &blob).unwrap_err();
    assert_eq!(e.dyn_into::<js_sys::Error>().unwrap().name(), "Decrypt");
    assert_eq!(engine.sign_vault(id, &blob).len(), 64);
}

#[wasm_bindgen_test]
fn export_roundtrip_wasm() {
    let state = WasmRelayEngine::create("web".into()).export_state();
    let text = seal_export("une phrase de passe", &state);
    assert!(text.starts_with("relaystate2:"));
    assert_eq!(open_export(Some("une phrase de passe".into()), &text).unwrap(), state);
    let e = open_export(None, &text).unwrap_err();
    assert_eq!(e.dyn_into::<js_sys::Error>().unwrap().name(), "Passphrase");
}
