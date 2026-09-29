//! The wallet walletd serves, and its background sync.
//!
//! The GUI starts walletd (`serve --await-wallet`) before the vault is unlocked, then
//! hands it the vault seed with `open_wallet` and takes it back with `close_wallet` on
//! lock. Each wallet keeps its state in `<root>/wallets/<wallet id>/`.
//!
//! Before that existed, walletd generated its own `master_seed.bin` and scanned,
//! received and sent with that seed, not the vault's. If that file is present it is
//! opened as the *legacy* wallet so its funds can be swept into the vault wallet. The
//! file is never deleted.

use crate::wallet_service::{open_state_db, wallet_id, WalletService};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::Mutex;
use zeroize::Zeroize;

pub type SharedWallet = Arc<Mutex<WalletService>>;

struct Loaded {
    id: String,
    service: SharedWallet,
    sync: tokio::task::JoinHandle<()>,
}

impl Loaded {
    fn start(service: WalletService) -> Self {
        let id = service.id();
        let engine = service.sync_engine();
        let sync = tokio::spawn(async move { engine.sync_loop().await });
        Self { id, service: Arc::new(Mutex::new(service)), sync }
    }
}

impl Drop for Loaded {
    /// Stops the sync. Its progress is on disk up to the last completed batch, which
    /// is written atomically, so stopping mid-batch loses nothing.
    fn drop(&mut self) {
        self.sync.abort();
    }
}

#[derive(Default)]
struct SlotState {
    open: Option<Loaded>,
    legacy: Option<Loaded>,
    /// sled allows one handle per database per process; reopening a wallet reuses it.
    dbs: HashMap<String, sled::Db>,
}

pub struct WalletSlot {
    root: PathBuf,
    daemon_url: String,
    testnet: bool,
    state: Mutex<SlotState>,
}

fn id_for_seed(seed: &[u8; 32]) -> Result<String, String> {
    let wallet = fuego_sdk::Wallet::from_seed(*seed).map_err(|e| e.to_string())?;
    Ok(wallet_id(&wallet.wallet_keys()))
}

impl WalletSlot {
    pub fn new(root: PathBuf, daemon_url: &str, testnet: bool) -> Self {
        Self {
            root,
            daemon_url: daemon_url.to_string(),
            testnet,
            state: Mutex::new(SlotState::default()),
        }
    }

    /// The open wallet, if any.
    pub async fn current(&self) -> Option<SharedWallet> {
        self.state.lock().await.open.as_ref().map(|l| l.service.clone())
    }

    /// The pre-vault walletd wallet, if one was found and differs from the open one.
    pub async fn legacy(&self) -> Option<SharedWallet> {
        self.state.lock().await.legacy.as_ref().map(|l| l.service.clone())
    }

    /// Open the wallet for `seed`, replacing any other open wallet. Returns its id.
    pub async fn open(&self, mut seed: [u8; 32]) -> Result<String, String> {
        let result = self.open_inner(&seed).await;
        seed.zeroize();
        result
    }

    async fn open_inner(&self, seed: &[u8; 32]) -> Result<String, String> {
        let id = id_for_seed(seed)?;
        let mut st = self.state.lock().await;
        if st.open.as_ref().is_some_and(|l| l.id == id) {
            return Ok(id);
        }
        st.open = None;
        if st.legacy.as_ref().is_some_and(|l| l.id == id) {
            st.open = st.legacy.take();
            return Ok(id);
        }
        let db = match st.dbs.get(&id) {
            Some(db) => db.clone(),
            None => {
                let db = open_state_db(&self.root.join("wallets").join(&id)).map_err(|e| e.to_string())?;
                st.dbs.insert(id.clone(), db.clone());
                db
            }
        };
        let service =
            WalletService::open(*seed, &self.daemon_url, db, self.testnet).map_err(|e| e.to_string())?;
        st.open = Some(Loaded::start(service));
        Ok(id)
    }

    /// Open `seed` on the state database in `dir`: the headless `--seed` /
    /// `master_seed.bin` wallet as the open one, or with `as_legacy` as the legacy one.
    pub async fn open_at(&self, mut seed: [u8; 32], dir: &Path, as_legacy: bool) -> Result<String, String> {
        let result = async {
            let id = id_for_seed(&seed)?;
            let mut st = self.state.lock().await;
            if as_legacy && st.open.as_ref().is_some_and(|l| l.id == id) {
                return Ok(id);
            }
            let db = match st.dbs.get(&id) {
                Some(db) => db.clone(),
                None => {
                    let db = open_state_db(dir).map_err(|e| e.to_string())?;
                    st.dbs.insert(id.clone(), db.clone());
                    db
                }
            };
            let service =
                WalletService::open(seed, &self.daemon_url, db, self.testnet).map_err(|e| e.to_string())?;
            let loaded = Some(Loaded::start(service));
            if as_legacy {
                st.legacy = loaded;
            } else {
                st.open = loaded;
            }
            Ok(id)
        }
        .await;
        seed.zeroize();
        result
    }

    /// Close the open wallet and stop its sync. Returns whether one was open.
    pub async fn close(&self) -> bool {
        self.state.lock().await.open.take().is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "fuego-slot-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ))
    }

    #[tokio::test]
    async fn open_close_reopen_and_switch() {
        let root = temp_root("switch");
        let slot = WalletSlot::new(root.clone(), "http://127.0.0.1:1", false);
        assert!(slot.current().await.is_none());

        let a = slot.open([1u8; 32]).await.unwrap();
        let addr_a = slot.current().await.unwrap().lock().await.primary_address_string();
        assert_eq!(slot.open([1u8; 32]).await.unwrap(), a, "same seed: no-op");
        assert!(root.join("wallets").join(&a).join("wallet_state.sled").exists());

        let b = slot.open([2u8; 32]).await.unwrap();
        assert_ne!(a, b);
        assert_ne!(slot.current().await.unwrap().lock().await.primary_address_string(), addr_a);

        assert!(slot.close().await);
        assert!(slot.current().await.is_none());
        assert!(!slot.close().await);

        // Reopening reuses the same sled handle (a second sled::open would fail).
        assert_eq!(slot.open([1u8; 32]).await.unwrap(), a);
        assert_eq!(slot.current().await.unwrap().lock().await.primary_address_string(), addr_a);
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn legacy_wallet_is_promoted_when_its_seed_is_opened() {
        let root = temp_root("legacy");
        let slot = WalletSlot::new(root.clone(), "http://127.0.0.1:1", false);
        let id = slot.open_at([3u8; 32], &root, true).await.unwrap();
        assert!(slot.legacy().await.is_some());
        assert_eq!(slot.open([3u8; 32]).await.unwrap(), id);
        assert!(slot.legacy().await.is_none(), "one wallet, not two syncs");
        assert!(slot.current().await.is_some());
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn walletd_address_is_the_vault_address() {
        // The GUI shows fuego_vault_get_address(vault, 0); walletd must receive on it.
        let root = temp_root("addr");
        let slot = WalletSlot::new(root.clone(), "http://127.0.0.1:1", false);
        let seed = [0x9cu8; 32];
        slot.open(seed).await.unwrap();
        let walletd = slot.current().await.unwrap().lock().await.primary_address_string();
        assert_eq!(walletd, fuego_sdk::WalletVault::from_seed(seed).get_address(0).0);
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn state_of_another_wallet_is_refused() {
        let root = temp_root("guard");
        let db = open_state_db(&root).unwrap();
        drop(WalletService::open([4u8; 32], "http://127.0.0.1:1", db.clone(), false).unwrap());
        let err = WalletService::open([5u8; 32], "http://127.0.0.1:1", db, false).err().unwrap();
        assert!(err.to_string().contains("belongs to wallet"));
        let _ = std::fs::remove_dir_all(root);
    }
}
