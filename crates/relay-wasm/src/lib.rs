//! wasm-bindgen surface of relay-core (`docs/specs/core-api.md`) for the web client.
//! Same API as the Swift one: camelCase methods, JSON strings for structs,
//! `Uint8Array` for bytes. Errors are thrown as `Error` whose `name` is the
//! RelayError variant (`InvalidCard`, `KeyChanged`, ...).

use std::cell::RefCell;

use js_sys::{Array, Object, Reflect, Uint8Array};
use relay_core as core;
use wasm_bindgen::prelude::*;

fn err(e: core::RelayError) -> JsValue {
    let x = js_sys::Error::new(e.message());
    x.set_name(e.kind());
    x.into()
}

fn json<T: serde::Serialize>(v: &T) -> String {
    serde_json::to_string(v).unwrap_or_else(|_| "null".into())
}

fn bytes_array(v: Vec<Vec<u8>>) -> Array {
    v.into_iter().map(|b| JsValue::from(Uint8Array::from(b.as_slice()))).collect()
}

fn strings(v: Vec<String>) -> Array {
    v.into_iter().map(JsValue::from).collect()
}

#[wasm_bindgen(js_name = RelayEngine)]
pub struct WasmRelayEngine {
    inner: RefCell<core::RelayEngine>,
}

#[wasm_bindgen(js_class = RelayEngine)]
impl WasmRelayEngine {
    /// New identity.
    pub fn create(display_name: String) -> WasmRelayEngine {
        WasmRelayEngine { inner: RefCell::new(core::RelayEngine::create(display_name)) }
    }

    /// From `exportState()`.
    pub fn restore(state: &[u8]) -> Result<WasmRelayEngine, JsValue> {
        Ok(WasmRelayEngine { inner: RefCell::new(core::RelayEngine::restore(state).map_err(err)?) })
    }

    #[wasm_bindgen(js_name = exportState)]
    pub fn export_state(&self) -> Vec<u8> {
        self.inner.borrow().export_state()
    }

    #[wasm_bindgen(js_name = fingerprintHex)]
    pub fn fingerprint_hex(&self) -> String {
        self.inner.borrow().fingerprint_hex()
    }

    #[wasm_bindgen(js_name = safetyWords)]
    pub fn safety_words(&self) -> Array {
        strings(self.inner.borrow().safety_words())
    }

    #[wasm_bindgen(js_name = mailboxHex)]
    pub fn mailbox_hex(&self) -> String {
        self.inner.borrow().mailbox_hex()
    }

    #[wasm_bindgen(js_name = displayName)]
    pub fn display_name(&self) -> String {
        self.inner.borrow().display_name()
    }

    #[wasm_bindgen(js_name = setDisplayName)]
    pub fn set_display_name(&self, name: String) {
        self.inner.borrow_mut().set_display_name(name)
    }

    #[wasm_bindgen(js_name = myCard)]
    pub fn my_card(&self, node_url: Option<String>, handle: Option<String>) -> String {
        self.inner.borrow_mut().my_card(node_url, handle)
    }

    #[wasm_bindgen(js_name = myCompactLink)]
    pub fn my_compact_link(&self, node_url: Option<String>) -> String {
        self.inner.borrow().my_compact_link(node_url)
    }

    #[wasm_bindgen(js_name = deviceSigningPublic)]
    pub fn device_signing_public(&self) -> Vec<u8> {
        self.inner.borrow().device_signing_public()
    }

    #[wasm_bindgen(js_name = signNodeChallenge)]
    pub fn sign_node_challenge(&self, nonce: &[u8]) -> Vec<u8> {
        self.inner.borrow().sign_node_challenge(nonce)
    }

    /// Own card carrying `handle` plus its directory signature, as JSON
    /// `{"card": "relay1:...", "sig_b64": "<base64url>"}`. PUT `card` as the body of
    /// `/v1/directory/{handle}` with `X-Relay-Sig: sig_b64`.
    #[wasm_bindgen(js_name = signDirectoryEntry)]
    pub fn sign_directory_entry(&self, handle: String) -> Result<String, JsValue> {
        let (card, sig) = self.inner.borrow_mut().sign_directory_entry(&handle).map_err(err)?;
        Ok(json(&serde_json::json!({"card": card, "sig_b64": core::util::b64url(&sig)})))
    }

    #[wasm_bindgen(js_name = rotatePrekeyIfDue)]
    pub fn rotate_prekey_if_due(&self, now_ms: f64) -> bool {
        self.inner.borrow_mut().rotate_prekey_if_due(now_ms as i64)
    }

    #[wasm_bindgen(js_name = addContact)]
    pub fn add_contact(&self, card: String) -> Result<String, JsValue> {
        Ok(json(&self.inner.borrow_mut().add_contact(&card).map_err(err)?))
    }

    #[wasm_bindgen(js_name = addContactReplacing)]
    pub fn add_contact_replacing(&self, card: String) -> Result<String, JsValue> {
        Ok(json(&self.inner.borrow_mut().add_contact_replacing(&card).map_err(err)?))
    }

    #[wasm_bindgen(js_name = parseCompactLink)]
    pub fn parse_compact_link(&self, link: String) -> Result<String, JsValue> {
        Ok(json(&self.inner.borrow().parse_compact_link(&link).map_err(err)?))
    }

    pub fn contacts(&self) -> String {
        self.inner.borrow().contacts()
    }

    #[wasm_bindgen(js_name = removeContact)]
    pub fn remove_contact(&self, fp: String) {
        self.inner.borrow_mut().remove_contact(&fp)
    }

    #[wasm_bindgen(js_name = setVerified)]
    pub fn set_verified(&self, fp: String, verified: bool) {
        self.inner.borrow_mut().set_verified(&fp, verified)
    }

    #[wasm_bindgen(js_name = renameContact)]
    pub fn rename_contact(&self, fp: String, name: String) {
        self.inner.borrow_mut().rename_contact(&fp, name)
    }

    #[wasm_bindgen(js_name = contactSafetyWords)]
    pub fn contact_safety_words(&self, fp: String) -> Array {
        strings(self.inner.borrow().contact_safety_words(&fp))
    }

    #[wasm_bindgen(js_name = contactSafetyCode)]
    pub fn contact_safety_code(&self, fp: String) -> String {
        self.inner.borrow().contact_safety_code(&fp)
    }

    #[wasm_bindgen(js_name = encryptFor)]
    pub fn encrypt_for(&self, fp: String, app_message_json: String) -> Result<Vec<u8>, JsValue> {
        self.inner.borrow_mut().encrypt_for(&fp, &app_message_json).map_err(err)
    }

    #[wasm_bindgen(js_name = meshTagFor)]
    pub fn mesh_tag_for(&self, fp: String, now_ms: f64) -> Vec<u8> {
        self.inner.borrow_mut().mesh_tag_for(&fp, now_ms as i64)
    }

    #[wasm_bindgen(js_name = retagForMesh)]
    pub fn retag_for_mesh(&self, envelope: &[u8], fp: String, now_ms: f64) -> Vec<u8> {
        self.inner.borrow_mut().retag_for_mesh(envelope, &fp, now_ms as i64)
    }

    /// InboundJson string, or `undefined` when the envelope is not for us.
    pub fn open(&self, envelope: &[u8], now_ms: f64) -> Result<Option<String>, JsValue> {
        self.inner.borrow_mut().open(envelope, now_ms as i64).map_err(err)
    }

    #[wasm_bindgen(js_name = createGroup)]
    pub fn create_group(&self, name: String, member_fps: Vec<String>) -> Result<String, JsValue> {
        self.inner.borrow_mut().create_group(name, member_fps).map_err(err)
    }

    /// `Uint8Array[]`: distribution envelopes first, the group envelope last.
    #[wasm_bindgen(js_name = groupEncrypt)]
    pub fn group_encrypt(&self, group_id: String, app_message_json: String) -> Result<Array, JsValue> {
        Ok(bytes_array(self.inner.borrow_mut().group_encrypt(&group_id, &app_message_json).map_err(err)?))
    }

    pub fn groups(&self) -> String {
        self.inner.borrow().groups()
    }

    #[wasm_bindgen(js_name = groupAdd)]
    pub fn group_add(&self, group_id: String, fp: String) -> Result<Array, JsValue> {
        Ok(bytes_array(self.inner.borrow_mut().group_add(&group_id, &fp).map_err(err)?))
    }

    #[wasm_bindgen(js_name = groupRemove)]
    pub fn group_remove(&self, group_id: String, fp: String) -> Result<Array, JsValue> {
        Ok(bytes_array(self.inner.borrow_mut().group_remove(&group_id, &fp).map_err(err)?))
    }

    #[wasm_bindgen(js_name = leaveGroup)]
    pub fn leave_group(&self, group_id: String) {
        self.inner.borrow_mut().leave_group(&group_id)
    }

    #[wasm_bindgen(js_name = channelEncrypt)]
    pub fn channel_encrypt(&self, name: String, password: Option<String>, app_message_json: String) -> Result<Vec<u8>, JsValue> {
        self.inner.borrow_mut().channel_encrypt(&name, password, &app_message_json).map_err(err)
    }

    #[wasm_bindgen(js_name = joinChannel)]
    pub fn join_channel(&self, name: String, password: Option<String>) -> Result<(), JsValue> {
        self.inner.borrow_mut().join_channel(&name, password).map_err(err)
    }

    #[wasm_bindgen(js_name = leaveChannel)]
    pub fn leave_channel(&self, name: String) {
        self.inner.borrow_mut().leave_channel(&name)
    }

    /// `key(32) || sha256(32) || ciphertext`.
    #[wasm_bindgen(js_name = sealAttachment)]
    pub fn seal_attachment(&self, plain: &[u8]) -> Vec<u8> {
        self.inner.borrow_mut().seal_attachment(plain)
    }

    #[wasm_bindgen(js_name = openAttachment)]
    pub fn open_attachment(&self, key: &[u8], sha256: &[u8], ciphertext: &[u8]) -> Result<Vec<u8>, JsValue> {
        core::RelayEngine::open_attachment(key, sha256, ciphertext).map_err(err)
    }

    #[wasm_bindgen(js_name = callKey)]
    pub fn call_key(&self, fp: String, call_id: String) -> Result<Vec<u8>, JsValue> {
        self.inner.borrow().call_key(&fp, &call_id).map_err(err)
    }

    /// `{id, kind, tag, ttl, size}` JSON (hex fields), to address an envelope.
    #[wasm_bindgen(js_name = envelopeInfo)]
    pub fn envelope_info(&self, envelope: &[u8]) -> Result<String, JsValue> {
        core::RelayEngine::envelope_info(envelope).map_err(err)
    }
}

#[wasm_bindgen(js_name = MeshRouter)]
pub struct WasmMeshRouter {
    inner: RefCell<core::MeshRouter>,
}

impl Default for WasmMeshRouter {
    fn default() -> Self {
        Self::new()
    }
}

#[wasm_bindgen(js_class = MeshRouter)]
impl WasmMeshRouter {
    #[wasm_bindgen(constructor)]
    pub fn new() -> WasmMeshRouter {
        WasmMeshRouter { inner: RefCell::new(core::MeshRouter::new()) }
    }

    /// Returns `{ complete: Uint8Array | null, forward: Uint8Array[], excludeLink: number }`.
    #[wasm_bindgen(js_name = onFrame)]
    pub fn on_frame(&self, frame: &[u8], from_link: u32, now_ms: f64) -> Result<Object, JsValue> {
        let r = self.inner.borrow_mut().on_frame(frame, from_link, now_ms as i64);
        let o = Object::new();
        let complete = r.complete.map_or(JsValue::NULL, |c| Uint8Array::from(c.as_slice()).into());
        Reflect::set(&o, &"complete".into(), &complete)?;
        Reflect::set(&o, &"forward".into(), &bytes_array(r.forward))?;
        Reflect::set(&o, &"excludeLink".into(), &JsValue::from(r.exclude_link))?;
        Ok(o)
    }

    #[wasm_bindgen(js_name = framesFor)]
    pub fn frames_for(&self, envelope: &[u8], mtu: u32) -> Array {
        bytes_array(self.inner.borrow_mut().frames_for(envelope, mtu))
    }
}
