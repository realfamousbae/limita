//! Secrets Limita keeps for itself, such as the DeepSeek API key. Port of
//! `KeychainStore.swift`.
//!
//! On Windows the key is a generic credential in the Windows Credential Manager, under
//! the user's account and on this machine only; it is never written to `settings.json`,
//! never logged and never sent to the webview. Elsewhere (a development build on macOS)
//! it is kept in memory until the app quits.

use std::sync::Mutex;

/// Where a secret is kept: the Credential Manager in the app, memory in tests.
pub trait SecretStore: Send + Sync {
    /// The stored secret, `None` when there is none.
    fn read(&self) -> Result<Option<String>, String>;
    /// Stores `value`, replacing any earlier one.
    fn save(&self, value: &str) -> Result<(), String>;
    /// Removes the secret; removing nothing is fine.
    fn delete(&self) -> Result<(), String>;
}

/// A secret in memory, for tests.
#[derive(Default)]
pub struct MemorySecret(Mutex<Option<String>>);

impl MemorySecret {
    pub fn new(value: Option<&str>) -> Self {
        Self(Mutex::new(value.map(String::from)))
    }
}

impl SecretStore for MemorySecret {
    fn read(&self) -> Result<Option<String>, String> {
        Ok(self.0.lock().unwrap_or_else(|p| p.into_inner()).clone())
    }

    fn save(&self, value: &str) -> Result<(), String> {
        *self.0.lock().unwrap_or_else(|p| p.into_inner()) = Some(value.into());
        Ok(())
    }

    fn delete(&self) -> Result<(), String> {
        *self.0.lock().unwrap_or_else(|p| p.into_inner()) = None;
        Ok(())
    }
}

/// A generic credential named `target` in the Windows Credential Manager.
#[derive(Clone, Debug)]
pub struct CredentialStore {
    pub target: String,
}

impl CredentialStore {
    /// The DeepSeek API key. Fake runs (`LIMITA_DEEPSEEK_API`) use a credential of their
    /// own, so trying the fake server never touches the real key.
    pub fn deepseek() -> Self {
        Self { target: deepseek_target(crate::deepseek_live::api_override().is_some()).into() }
    }
}

fn deepseek_target(fake: bool) -> &'static str {
    if fake { "Limita/fake/deepseek-api-key" } else { "Limita/deepseek-api-key" }
}

#[cfg(windows)]
mod credential_manager {
    use windows_sys::Win32::Foundation::{GetLastError, ERROR_NOT_FOUND, FILETIME};
    use windows_sys::Win32::Security::Credentials::{
        CredDeleteW, CredFree, CredReadW, CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC,
    };

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(Some(0)).collect()
    }

    pub fn read(target: &str) -> Result<Option<String>, String> {
        let name = wide(target);
        let mut credential: *mut CREDENTIALW = std::ptr::null_mut();
        // SAFETY: `name` is NUL-terminated and outlives the call; on success the
        // credential is valid until `CredFree`.
        unsafe {
            if CredReadW(name.as_ptr(), CRED_TYPE_GENERIC, 0, &mut credential) == 0 {
                let error = GetLastError();
                return if error == ERROR_NOT_FOUND {
                    Ok(None)
                } else {
                    Err(format!("Could not read the key in the Credential Manager (error {error})"))
                };
            }
            let blob = &*credential;
            let bytes = if blob.CredentialBlob.is_null() {
                Vec::new()
            } else {
                std::slice::from_raw_parts(blob.CredentialBlob, blob.CredentialBlobSize as usize).to_vec()
            };
            CredFree(credential as *const _);
            String::from_utf8(bytes).map(Some).map_err(|_| "The key in the Credential Manager is not text".into())
        }
    }

    pub fn save(target: &str, value: &str) -> Result<(), String> {
        let mut name = wide(target);
        let mut user = wide("api-key");
        let mut blob = value.as_bytes().to_vec();
        let credential = CREDENTIALW {
            Flags: 0,
            Type: CRED_TYPE_GENERIC,
            TargetName: name.as_mut_ptr(),
            Comment: std::ptr::null_mut(),
            LastWritten: FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 },
            CredentialBlobSize: blob.len() as u32,
            CredentialBlob: blob.as_mut_ptr(),
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            AttributeCount: 0,
            Attributes: std::ptr::null_mut(),
            TargetAlias: std::ptr::null_mut(),
            UserName: user.as_mut_ptr(),
        };
        // SAFETY: every pointer in `credential` points into a buffer that outlives the call.
        if unsafe { CredWriteW(&credential, 0) } == 0 {
            let error = unsafe { GetLastError() };
            return Err(format!("Could not save the key in the Credential Manager (error {error})"));
        }
        Ok(())
    }

    pub fn delete(target: &str) -> Result<(), String> {
        let name = wide(target);
        // SAFETY: `name` is NUL-terminated and outlives the call.
        unsafe {
            if CredDeleteW(name.as_ptr(), CRED_TYPE_GENERIC, 0) == 0 {
                let error = GetLastError();
                if error != ERROR_NOT_FOUND {
                    return Err(format!("Could not remove the key from the Credential Manager (error {error})"));
                }
            }
        }
        Ok(())
    }
}

#[cfg(windows)]
impl SecretStore for CredentialStore {
    fn read(&self) -> Result<Option<String>, String> {
        credential_manager::read(&self.target)
    }

    fn save(&self, value: &str) -> Result<(), String> {
        credential_manager::save(&self.target, value)
    }

    fn delete(&self) -> Result<(), String> {
        credential_manager::delete(&self.target)
    }
}

/// Development builds elsewhere: per target, in memory, until the process ends.
#[cfg(not(windows))]
static DEVELOPMENT_SECRETS: Mutex<std::collections::BTreeMap<String, String>> = Mutex::new(std::collections::BTreeMap::new());

#[cfg(not(windows))]
impl SecretStore for CredentialStore {
    fn read(&self) -> Result<Option<String>, String> {
        Ok(DEVELOPMENT_SECRETS.lock().unwrap_or_else(|p| p.into_inner()).get(&self.target).cloned())
    }

    fn save(&self, value: &str) -> Result<(), String> {
        DEVELOPMENT_SECRETS.lock().unwrap_or_else(|p| p.into_inner()).insert(self.target.clone(), value.into());
        Ok(())
    }

    fn delete(&self) -> Result<(), String> {
        DEVELOPMENT_SECRETS.lock().unwrap_or_else(|p| p.into_inner()).remove(&self.target);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The real Credential Manager on Windows, with a credential of its own that the test
    /// removes; memory elsewhere.
    #[test]
    fn saves_replaces_and_deletes() {
        let store = CredentialStore { target: format!("Limita/tests/{}", std::process::id()) };
        assert_eq!(store.read(), Ok(None));
        store.save("sk-first").unwrap();
        assert_eq!(store.read(), Ok(Some("sk-first".into())));
        store.save("sk-second").unwrap();
        assert_eq!(store.read(), Ok(Some("sk-second".into())), "a second save replaces the credential");
        store.delete().unwrap();
        assert_eq!(store.read(), Ok(None));
        assert_eq!(store.delete(), Ok(()), "deleting nothing is fine");
    }

    #[test]
    fn fake_runs_keep_their_own_key() {
        assert_eq!(deepseek_target(false), "Limita/deepseek-api-key");
        assert_ne!(deepseek_target(true), deepseek_target(false));
        let memory = MemorySecret::new(Some("sk-x"));
        assert_eq!(memory.read(), Ok(Some("sk-x".into())));
        memory.delete().unwrap();
        assert_eq!(memory.read(), Ok(None));
    }
}
