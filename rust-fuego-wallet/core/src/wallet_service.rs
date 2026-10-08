use crate::daemon::DaemonClient;

use fuego_sdk::*;
use fuego_sdk::amm;
use fuego_sdk::scanner::{CommitmentEntry, UtxoEntry};
use fuego_sdk::serialization::{is_marker_term, DEPOSIT_TERM_LP, HEAT_TERM};
use fuego_sdk::transaction_builder::{
    address_hash, build_v11_transaction, layout_cancel_order, layout_cd_create,
    layout_cd_rollover, layout_cd_withdraw, layout_heat_send, layout_lp_add, layout_lp_remove,
    layout_mint, layout_place_order, layout_swap, AddressKeys, CommitmentDeposit, DecoyEntry,
    V11Output, V11Spend, V11Tag, MINIMUM_FEE,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use zeroize::Zeroize;

/// Default ring size when the caller does not specify one (C++ API default
/// mixIn is 4).
const DEFAULT_MIXIN: usize = 4;
/// Inputs per sweep transaction; keeps a sweep of many small outputs under the size limit.
const MAX_SWEEP_INPUTS: usize = 50;
/// CryptoNoteConfig.h SWAP_FEE_RATE_BPS / SWAP_FEE_RATE_DIVISOR (AFK taker fee).
const SWAP_FEE_RATE_BPS: u64 = 100;
const SWAP_FEE_RATE_DIVISOR: u64 = 10000;
/// Atomic units per coin (CryptoNoteConfig.h COIN).
const COIN: u64 = 10_000_000;
/// CryptoNoteConfig.h DEPOSIT_MIN_TERM / DEPOSIT_MAX_TERM and their testnet
/// counterparts: the CD terms (blocks) consensus admits.
const DEPOSIT_MIN_TERM: u32 = 5400;
const DEPOSIT_MAX_TERM: u32 = 64800;
const TESTNET_DEPOSIT_MIN_TERM: u32 = 10;
const TESTNET_DEPOSIT_MAX_TERM: u32 = 720;
/// CryptoNoteConfig.h ORDERBOOK_MAX_ENDURANCE: the longest a limit order lives.
const ORDERBOOK_MAX_ENDURANCE: u32 = 20160;

/// Scale claims down pro rata when `available` cannot back them all
/// (makeWithdrawDepositRequest's scale).
fn scale_claims(claims: &mut [u64], available: u64) {
    let total: u128 = claims.iter().map(|c| *c as u128).sum();
    if total == 0 || available as u128 >= total {
        return;
    }
    for c in claims.iter_mut() {
        *c = (*c as u128 * available as u128 / total) as u64;
    }
}

/// CdBonusClaim entries (input index, bonus) for the CD inputs that follow
/// `key_inputs` key inputs on the wire.
fn bonus_claims_for(key_inputs: usize, bonus: &[u64]) -> std::result::Result<Vec<(u8, u64)>, String> {
    let mut out = Vec::new();
    for (i, b) in bonus.iter().enumerate() {
        if *b == 0 {
            continue;
        }
        let index = u8::try_from(key_inputs + i).map_err(|_| "too many inputs for a bonus claim".to_string())?;
        out.push((index, *b));
    }
    Ok(out)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AfkLockSecret {
    secret: [u8; 32],
    pre_sig: Vec<u8>,
    amount: u64,
    timeout_hours: u32,
    pair: u8,
}

/// Counterparty HTLC hashlock = H(adaptor secret t), per chain family
/// (SwapHashLock.h): keccak256(t) for Solana/EVM, sha256(t) for UTXO pairs.
/// Never H(T) — the counterparty program verifies H(preimage) where the
/// preimage revealed by claim() is t, not the adaptor point T = t*G.
fn afk_hash_lock(pair: u8, secret: &[u8; 32]) -> String {
    match pair {
        // BCH=3, KMD=6, DCR=8, BTC=9, LTC=10 — sha256 like bchHashLockHex.
        3 | 6 | 8 | 9 | 10 => {
            use sha2::Digest;
            let h = sha2::Sha256::digest(secret);
            hex::encode(h)
        }
        // SOL=0, ETH=1, ARB=4, BASE=5, BNB=7, POLYGON=11, XMR=2 (fallback
        // digest; XMR uses a different path) — keccak256 like solHashLockHex.
        _ => hex::encode(fuego_crypto::cn_fast_hash(secret)),
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PendingTx {
    tx_hash: [u8; 32],
    key_images: Vec<[u8; 32]>,
    serialized_hex: String,
    created_height: u64,
}

pub struct WalletService {
    pub wallet: Arc<Mutex<Wallet>>,
    pub daemon: DaemonClient,
    db: sled::Db,
    /// Hash of the last scanned block. Kept in memory with the height and written to
    /// disk only together with the scan state, so the two never disagree on disk.
    top: Arc<Mutex<Option<[u8; 32]>>>,
    testnet: bool,
    /// AFK adaptor secrets, keyed by lock id. In-memory only (like the C++
    /// WalletLegacy m_afkLockSecrets) — never persisted plaintext to sled.
    afk_secrets: Arc<Mutex<HashMap<String, AfkLockSecret>>>,
}

/// Background sync runner. Shares the wallet and daemon handles with the
/// service but never contends the server-facing mutex: the JSON-RPC handlers
/// stay responsive while sync batches are in flight.
#[derive(Clone)]
pub struct SyncEngine {
    pub wallet: Arc<Mutex<Wallet>>,
    pub daemon: DaemonClient,
    db: sled::Db,
    top: Arc<Mutex<Option<[u8; 32]>>>,
}

const KEY_HEIGHT: &[u8] = b"height";
const KEY_TOP_HASH: &[u8] = b"top_hash";
/// Which address received each owned output: Vec<([u8; 32], OutputOwner)>.
const KEY_OWNERS: &[u8] = b"owners";
/// Number of suite-scheme sub-addresses handed out (u32).
const KEY_SUBADDRESS_COUNT: &[u8] = b"subaddress_count";
/// Pre-suite-scheme sub-address indices to scan and sweep (Vec<u32>).
const KEY_LEGACY_SUBADDRESSES: &[u8] = b"legacy_subaddresses";
/// Set when the next sync must start over from genesis.
const KEY_RESCAN: &[u8] = b"rescan_requested";
/// Version of the scan rules the stored state was built with (u32).
const KEY_SCAN_VERSION: &[u8] = b"scan_version";
/// 2: vault secrets are reduced mod l (before, sc_check rejected most view keys,
/// so most wallets found no outputs) and sub-address outputs are detected.
/// State scanned under older rules is rebuilt once from genesis.
const SCAN_VERSION: u32 = 2;
/// Id of the wallet whose state this database holds (see `wallet_id`).
const KEY_WALLET_ID: &[u8] = b"wallet_id";

/// Stable, non-secret id for a wallet: the first 8 bytes of
/// Keccak("fuego-walletd-id" || spend_public || view_public), hex. Names its state directory.
pub fn wallet_id(keys: &fuego_sdk::scanner::WalletKeys) -> String {
    let mut data = b"fuego-walletd-id".to_vec();
    data.extend_from_slice(&keys.spend_public);
    data.extend_from_slice(&keys.view_public);
    hex::encode(&fuego_crypto::cn_fast_hash(&data)[..8])
}

fn db_get<T: serde::de::DeserializeOwned>(db: &sled::Db, key: &[u8]) -> Option<T> {
    db.get(key).ok().flatten().and_then(|b| bincode::deserialize::<T>(&b).ok())
}

fn db_put<T: serde::Serialize>(db: &sled::Db, key: &[u8], value: &T) {
    let _ = bincode::serialize(value).ok().and_then(|b| db.insert(key, b).ok());
}

/// Open (creating if needed) `<dir>/wallet_state.sled`, owner-only on Unix.
pub fn open_state_db(dir: &std::path::Path) -> Result<sled::Db> {
    std::fs::create_dir_all(dir).map_err(|e| SdkError::Storage(format!("create {dir:?}: {e}")))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    }
    sled::open(dir.join("wallet_state.sled")).map_err(|e| SdkError::Storage(format!("sled open: {e}")))
}

fn meta_tree(db: &sled::Db) -> sled::Tree {
    db.open_tree("meta").expect("open meta tree")
}

impl WalletService {
    pub fn new(seed: [u8; 32], daemon_url: &str, wallet_dir: PathBuf, testnet: bool) -> Result<Self> {
        Self::open(seed, daemon_url, open_state_db(&wallet_dir)?, testnet)
    }

    /// Open the wallet for `seed` on an already-open state database. Fails if the
    /// database holds another wallet's state.
    pub fn open(seed: [u8; 32], daemon_url: &str, db: sled::Db, testnet: bool) -> Result<Self> {
        let wallet = Wallet::from_seed(seed)?;
        let id = wallet_id(&wallet.wallet_keys());
        match db_get::<String>(&db, KEY_WALLET_ID) {
            Some(stored) if stored != id => {
                return Err(SdkError::Storage(format!(
                    "state database belongs to wallet {stored}, not {id}"
                )));
            }
            Some(_) => {}
            None => {
                db_put(&db, KEY_WALLET_ID, &id);
                let _ = db.flush();
            }
        }

        let service = Self {
            wallet: Arc::new(Mutex::new(wallet)),
            daemon: DaemonClient::new(daemon_url),
            db,
            top: Arc::new(Mutex::new(None)),
            testnet,
            afk_secrets: Arc::new(Mutex::new(HashMap::new())),
        };
        service.sync_engine().load_state();
        if db_get::<u32>(&service.db, KEY_SCAN_VERSION) != Some(SCAN_VERSION) {
            if service.wallet.lock().unwrap().height() > 0 {
                let _ = service.db.insert(KEY_RESCAN, &[1u8][..]);
            }
            db_put(&service.db, KEY_SCAN_VERSION, &SCAN_VERSION);
            let _ = service.db.flush();
        }
        Ok(service)
    }

    /// See `wallet_id`.
    pub fn id(&self) -> String {
        wallet_id(&self.wallet.lock().unwrap().wallet_keys())
    }

    /// True when (view_secret, spend_public) are this wallet's primary keys (hex).
    pub fn has_keys(&self, view_secret_hex: &str, spend_public_hex: &str) -> bool {
        let keys = self.wallet.lock().unwrap().wallet_keys();
        let eq = |hex_str: &str, key: &[u8; 32]| {
            let mut buf = [0u8; 32];
            let ok = hex::decode_to_slice(hex_str.trim(), &mut buf).is_ok()
                && buf.iter().zip(key).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0;
            buf.zeroize();
            ok
        };
        eq(view_secret_hex, &keys.view_secret) & eq(spend_public_hex, &keys.spend_public)
    }

    /// The wallet's primary address for the configured network.
    pub fn primary_address_string(&self) -> String {
        let keys = self.wallet.lock().unwrap().wallet_keys();
        let prefix = if self.testnet {
            fuego_crypto::TESTNET_ADDRESS_BASE58_PREFIX
        } else {
            fuego_crypto::ADDRESS_BASE58_PREFIX
        };
        fuego_crypto::make_address_with_prefix(&keys.spend_public, &keys.view_public, prefix).0
    }

    // ------------------------------------------------------------ state

    // ------------------------------------------------------------ sync

    /// One incremental sync round over /queryblockslite.bin. Returns the
    /// number of blocks scanned.
    pub async fn sync_once(&self) -> std::result::Result<u64, String> {
        self.sync_engine().sync_once().await
    }
}

impl SyncEngine {
    fn load_state(&self) {
        let db = &self.db;
        let wallet = self.wallet.lock().unwrap();

        if let Ok(Some(bytes)) = db.get(b"utxos") {
            if let Ok(utxos) = bincode::deserialize::<Vec<fuego_sdk::scanner::UtxoEntry>>(&bytes) {
                let snapshot = fuego_sdk::scanner::ScannerStateSnapshot {
                    height: db
                        .get(KEY_HEIGHT)
                        .ok()
                        .flatten()
                        .and_then(|b| bincode::deserialize::<u64>(&b).ok())
                        .unwrap_or(0),
                    utxos,
                    commitments: db
                        .get(b"commitments")
                        .ok()
                        .flatten()
                        .and_then(|b| bincode::deserialize::<Vec<fuego_sdk::scanner::CommitmentEntry>>(&b).ok())
                        .unwrap_or_default(),
                    spent_images: db
                        .get(b"spent")
                        .ok()
                        .flatten()
                        .and_then(|b| bincode::deserialize::<Vec<[u8; 32]>>(&b).ok())
                        .unwrap_or_default(),
                    history: db
                        .get(b"history")
                        .ok()
                        .flatten()
                        .and_then(|b| bincode::deserialize::<Vec<fuego_sdk::scanner::HistoryEntry>>(&b).ok())
                        .unwrap_or_default(),
                    owners: db_get(db, KEY_OWNERS).unwrap_or_default(),
                };
                wallet.restore_state(&snapshot);
            }
        }

        // Sub-addresses handed out so far, and legacy ones still to scan.
        let count: u32 = db_get(db, KEY_SUBADDRESS_COUNT).unwrap_or(0);
        if count > 0 {
            wallet.subaddress(count);
        }
        let legacy: Vec<u32> = db_get(db, KEY_LEGACY_SUBADDRESSES).unwrap_or_default();
        wallet.set_legacy_subaddresses(&legacy);

        // Re-reserve pending sends (persist-before-broadcast: never release
        // these automatically).
        if let Ok(Some(bytes)) = db.get(b"pending") {
            if let Ok(pending) = bincode::deserialize::<Vec<PendingTx>>(&bytes) {
                let images: Vec<[u8; 32]> = pending
                    .iter()
                    .flat_map(|p| p.key_images.clone())
                    .collect();
                wallet.reserve_pending(&images);
            }
        }
    }

    /// Write the scan state and the matching top-block hash in one atomic batch. The
    /// hash is read under the wallet lock, which the sync loop also holds while it
    /// advances both, so a crash or a cancelled sync never leaves the stored hash ahead
    /// of the stored height (that skipped the blocks in between on the next sync).
    fn persist_state(&self) {
        fn put<T: Serialize>(batch: &mut sled::Batch, key: &[u8], value: &T) {
            if let Ok(b) = bincode::serialize(value) {
                batch.insert(key, b);
            }
        }
        let mut batch = sled::Batch::default();
        {
            let wallet = self.wallet.lock().unwrap();
            let snapshot = wallet.snapshot_state();
            put(&mut batch, KEY_HEIGHT, &snapshot.height);
            put(&mut batch, b"utxos", &snapshot.utxos);
            put(&mut batch, b"commitments", &snapshot.commitments);
            put(&mut batch, b"spent", &snapshot.spent_images);
            put(&mut batch, b"history", &snapshot.history);
            put(&mut batch, KEY_OWNERS, &snapshot.owners);
            match self.top_hash() {
                Some(h) => put(&mut batch, KEY_TOP_HASH, &h),
                None => batch.remove(KEY_TOP_HASH),
            }
        }
        let _ = self.db.apply_batch(batch);
        let _ = self.db.flush();
    }

    fn top_hash(&self) -> Option<[u8; 32]> {
        if let Some(h) = *self.top.lock().unwrap() {
            return Some(h);
        }
        self.db
            .get(KEY_TOP_HASH)
            .ok()
            .flatten()
            .and_then(|b| bincode::deserialize::<[u8; 32]>(&b).ok())
    }

    fn pending(&self) -> Vec<PendingTx> {
        self.db
            .get(b"pending")
            .ok()
            .flatten()
            .and_then(|b| bincode::deserialize::<Vec<PendingTx>>(&b).ok())
            .unwrap_or_default()
    }

    fn store_pending(&self, list: &[PendingTx]) {
        let _ = bincode::serialize(list).ok().and_then(|b| self.db.insert(b"pending", b).ok());
        let _ = self.db.flush();
    }


    /// One incremental sync round over /queryblockslite.bin. Returns the
    /// number of blocks scanned.
    pub async fn sync_once(&self) -> std::result::Result<u64, String> {
        if matches!(self.db.get(KEY_RESCAN), Ok(Some(_))) {
            self.start_rescan();
        }
        let info = self.daemon.get_info().await?;
        let our_height = self.wallet.lock().unwrap().height();
        self.retry_missing_global_indices().await;

        if info.height <= our_height {
            return Ok(0);
        }

        // The daemon rejects locators whose LAST id is not the genesis hash
        // (Core.cpp findStartAndFullOffsets). Locator order is newest first,
        // genesis always last.
        let genesis_hex = self.daemon.get_block_hash(0).await?;
        let mut genesis = [0u8; 32];
        hex::decode_to_slice(genesis_hex.trim(), &mut genesis)
            .map_err(|e| format!("genesis hash: {e}"))?;

        let mut locator: Vec<[u8; 32]> = match self.top_hash() {
            Some(h) if our_height > 0 => vec![h],
            _ => Vec::new(),
        };
        locator.push(genesis);

        let resp = self.daemon.query_blocks_lite(&locator, 0).await?;
        let mut scanned = 0u64;

        for (k, item) in resp.items.iter().enumerate() {
            let block_height = resp.start_height + k as u64;
            // The daemon re-sends the block matching the locator; skip it.
            if Some(&item.block_id) == locator.first() && block_height <= our_height {
                continue;
            }

            for txi in &item.tx_prefixes {
                let prefix = &txi.parsed;
                let received = {
                    let wallet = self.wallet.lock().unwrap();
                    wallet
                        .scan_tx_prefix(&txi.tx_hash, &prefix, block_height)
                        .map_err(|e| format!("scan: {e}"))?
                        .0
                };

                if received > 0 {
                    match self.daemon.get_o_indexes(&txi.tx_hash).await {
                        Ok(indices) => {
                            let wallet = self.wallet.lock().unwrap();
                            wallet.attach_global_indices(&txi.tx_hash, &indices);
                        }
                        Err(e) => {
                            log::warn!("get_o_indexes failed for {}: {}", hex::encode(txi.tx_hash), e);
                        }
                    }
                }
            }

            // Remove pending sends that confirmed in this block.
            self.confirm_pending(&item.tx_prefixes);

            let wallet = self.wallet.lock().unwrap();
            wallet.set_height(block_height);
            *self.top.lock().unwrap() = Some(item.block_id);
            drop(wallet);
            scanned += 1;
        }

        if scanned > 0 {
            // Reconcile deep-confirmed utxos against the daemon's key image
            // index (covers outputs spent before a seed restore).
            self.reconcile_spent(our_height).await;
            self.persist_state();
        }

        Ok(scanned)
    }

    /// Background sync loop; never returns.
    pub async fn sync_loop(&self) {
        loop {
            match self.sync_once().await {
                Ok(0) => {
                    tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                }
                Ok(n) => {
                    log::info!("Synced {} blocks", n);
                }
                Err(e) => {
                    log::error!("Sync error: {}", e);
                    tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                }
            }
        }
    }

    /// Drop scanned state so the next round starts from genesis (run only on the
    /// sync task, so no batch in flight re-advances the height afterwards).
    /// Pending sends stay reserved.
    fn start_rescan(&self) {
        {
            let wallet = self.wallet.lock().unwrap();
            wallet.reset_scan_state();
            let images: Vec<[u8; 32]> =
                self.pending().iter().flat_map(|p| p.key_images.clone()).collect();
            wallet.reserve_pending(&images);
            *self.top.lock().unwrap() = None;
            let _ = self.db.remove(KEY_TOP_HASH);
        }
        self.persist_state();
        let _ = self.db.remove(KEY_RESCAN);
        let _ = self.db.flush();
        log::info!("rescanning from genesis");
    }

    /// Outputs whose `get_o_indexes` lookup failed during the scan keep the
    /// placeholder global index 0, which coin selection skips (index 0 is the
    /// genesis output). Retry them each round so they become spendable.
    async fn retry_missing_global_indices(&self) {
        let missing: std::collections::BTreeSet<[u8; 32]> = {
            let wallet = self.wallet.lock().unwrap();
            wallet
                .utxos()
                .iter()
                .filter(|u| u.global_index == 0)
                .map(|u| u.tx_hash)
                .chain(
                    wallet
                        .snapshot_state()
                        .commitments
                        .iter()
                        .filter(|c| c.global_index == 0)
                        .map(|c| c.tx_hash),
                )
                .collect()
        };
        let mut attached = false;
        for tx_hash in missing {
            match self.daemon.get_o_indexes(&tx_hash).await {
                Ok(indices) => {
                    self.wallet.lock().unwrap().attach_global_indices(&tx_hash, &indices);
                    attached = true;
                }
                Err(e) => log::warn!("get_o_indexes retry failed for {}: {}", hex::encode(tx_hash), e),
            }
        }
        if attached {
            self.persist_state();
        }
    }

    /// Remove pending entries whose transaction is now in a scanned block.
    fn confirm_pending(&self, prefixes: &[fuego_sdk::serialization::TxPrefixInfo]) {
        let mut pending = self.pending();
        if pending.is_empty() {
            return;
        }
        let confirmed: Vec<[u8; 32]> = prefixes.iter().map(|p| p.tx_hash).collect();
        let before = pending.len();
        pending.retain(|p| !confirmed.contains(&p.tx_hash));
        if pending.len() != before {
            self.store_pending(&pending);
        }
    }

    /// Ask the daemon whether any of our unspent outputs' key images are
    /// spent. Best-effort: if the endpoint is unavailable, scan-based
    /// tracking remains in effect.
    async fn reconcile_spent(&self, _our_height: u64) {
        let utxos = self.wallet.lock().unwrap().utxos();
        for utxo in utxos {
            match self.daemon.is_key_image_spent(&utxo.key_image).await {
                Ok(true) => {
                    log::info!(
                        "key image {} marked spent by daemon (tx {})",
                        hex::encode(utxo.key_image),
                        hex::encode(utxo.tx_hash)
                    );
                    let wallet = self.wallet.lock().unwrap();
                    wallet.reserve_pending(&[utxo.key_image]);
                }
                Ok(false) => {}
                Err(_) => return, // endpoint missing: stop, rely on scans
            }
        }
    }
}

impl WalletService {
    /// The background sync engine, detached from the service mutex.
    pub fn sync_engine(&self) -> SyncEngine {
        SyncEngine {
            wallet: self.wallet.clone(),
            daemon: self.daemon.clone(),
            db: self.db.clone(),
            top: self.top.clone(),
        }
    }

    // ------------------------------------------------------------ send

    /// Build, persist and broadcast a transaction. `anonymity` is the
    /// requested mixin (0 → default 4).
    pub async fn send_transaction(
        &self,
        destinations: &[(String, u64)],
        fee: u64,
        anonymity: u32,
    ) -> std::result::Result<String, String> {
        let fee = fee.max(MINIMUM_FEE);
        let mixin = if anonymity == 0 {
            DEFAULT_MIXIN
        } else {
            (anonymity as usize).min(fuego_sdk::transaction_builder::MAX_MIXIN)
        };

        let total: u64 = destinations.iter().map(|(_, a)| *a).sum::<u64>() + fee;

        let selected = {
            let wallet = self.wallet.lock().unwrap();
            wallet
                .select_for_send(total, &mut rand::thread_rng())
                .map_err(|e| format!("coin selection: {e}"))?
        };

        let decoys = self.fetch_decoys(&selected, mixin).await?;

        let dests: Vec<(fuego_sdk::Address, u64)> = destinations
            .iter()
            .map(|(addr, amount)| (fuego_sdk::Address(addr.clone()), *amount))
            .collect();

        let built = {
            let wallet = self.wallet.lock().unwrap();
            wallet
                .build_with_selection(&selected, &dests, fee, mixin, &decoys, &mut rand::thread_rng())
                .map_err(|e| format!("build: {e}"))?
        };

        let key_images: Vec<[u8; 32]> = selected.iter().map(|u| u.key_image).collect();
        self.broadcast_built(built, key_images).await
    }

    /// Fetch `mixin` decoys for each selected input, excluding the real output.
    async fn fetch_decoys(
        &self,
        selected: &[fuego_sdk::scanner::UtxoEntry],
        mixin: usize,
    ) -> std::result::Result<Vec<Vec<DecoyEntry>>, String> {
        let amounts: Vec<u64> = selected.iter().map(|u| u.amount).collect();
        let groups = self.daemon.get_random_outs(&amounts, (mixin + 1) as u64).await?;

        let mut decoys: Vec<Vec<DecoyEntry>> = Vec::with_capacity(selected.len());
        for utxo in selected.iter() {
            let group = groups
                .iter()
                .find(|g| g.amount == utxo.amount)
                .ok_or_else(|| format!("daemon returned no decoys for amount {}", utxo.amount))?;

            let mut entries: Vec<DecoyEntry> = group
                .outs
                .iter()
                .filter(|o| o.global_amount_index != utxo.global_index as u64)
                .map(|o| DecoyEntry {
                    global_index: o.global_amount_index as u32,
                    out_key: o.out_key,
                })
                .collect();
            entries.sort_by_key(|e| e.global_index);
            entries.truncate(mixin);

            if entries.len() < mixin && mixin > 0 {
                return Err(format!(
                    "MIXIN_COUNT_TOO_BIG: only {} decoys available for amount {} (requested {})",
                    entries.len(),
                    utxo.amount,
                    mixin
                ));
            }
            decoys.push(entries);
        }

        Ok(decoys)
    }

    // ------------------------------------------------------------ sub-addresses

    fn address_prefix(&self) -> u64 {
        if self.testnet {
            fuego_crypto::TESTNET_ADDRESS_BASE58_PREFIX
        } else {
            fuego_crypto::ADDRESS_BASE58_PREFIX
        }
    }

    /// Suite-scheme sub-address `minor` (>= 1) as a string for this network.
    fn subaddress_string(&self, minor: u32) -> Option<String> {
        let (spend, view) = self.wallet.lock().unwrap().subaddress(minor)?;
        Some(fuego_crypto::make_address_with_prefix(&spend, &view, self.address_prefix()).0)
    }

    /// Hand out the next sub-address. Returns (index, address).
    pub fn create_subaddress(&self) -> std::result::Result<(u32, String), String> {
        let next = db_get::<u32>(&self.db, KEY_SUBADDRESS_COUNT).unwrap_or(0) + 1;
        let address = self.subaddress_string(next).ok_or("sub-address derivation failed")?;
        db_put(&self.db, KEY_SUBADDRESS_COUNT, &next);
        let _ = self.db.flush();
        Ok((next, address))
    }

    /// Every handed-out sub-address with its unspent balance, then legacy
    /// sub-addresses with the balance still waiting to be swept.
    pub fn list_subaddresses(&self) -> (Vec<(u32, String, u64)>, Vec<(u32, u64)>) {
        use fuego_sdk::scanner::OutputOwner;
        let count: u32 = db_get(&self.db, KEY_SUBADDRESS_COUNT).unwrap_or(0);
        let (balances, legacy) = {
            let wallet = self.wallet.lock().unwrap();
            (wallet.balance_by_owner(), wallet.legacy_subaddresses())
        };
        let subs = (1..=count)
            .filter_map(|n| {
                let addr = self.subaddress_string(n)?;
                Some((n, addr, *balances.get(&OutputOwner::Subaddress(n)).unwrap_or(&0)))
            })
            .collect();
        let legacy = legacy
            .into_iter()
            .map(|n| (n, *balances.get(&OutputOwner::LegacySubaddress(n)).unwrap_or(&0)))
            .collect();
        (subs, legacy)
    }

    /// Start scanning pre-suite-scheme sub-addresses (vault keys n, n + 1).
    /// New indices trigger one rescan from genesis, since their outputs may
    /// already be on chain. Returns true when a rescan was scheduled.
    pub fn register_legacy_subaddresses(&self, indices: &[u32]) -> bool {
        let grew = self.wallet.lock().unwrap().set_legacy_subaddresses(indices);
        if grew {
            let all = self.wallet.lock().unwrap().legacy_subaddresses();
            db_put(&self.db, KEY_LEGACY_SUBADDRESSES, &all);
            let _ = self.db.insert(KEY_RESCAN, &[1u8][..]);
            let _ = self.db.flush();
        }
        grew
    }

    /// Move every confirmed output on legacy sub-addresses to the primary
    /// address. Legacy sub-address 1's spend key equals the primary view key,
    /// so anything left there is spendable by whoever holds the view key.
    pub async fn sweep_legacy_subaddresses(&self) -> std::result::Result<Option<String>, String> {
        let selected: Vec<_> = self
            .wallet
            .lock()
            .unwrap()
            .legacy_utxos()
            .into_iter()
            .filter(|u| u.global_index != 0)
            .collect();
        let own = self.primary_address_string();
        self.sweep_to(selected, &own).await.map(|(tx, _)| tx)
    }

    /// Send this wallet's confirmed outputs to `address`, at most `MAX_SWEEP_INPUTS`
    /// per transaction (largest first). Returns the tx hash, if one was sent, and how
    /// many outputs are left for the next call. Moves an older walletd wallet's funds
    /// into the vault wallet.
    pub async fn sweep_all_to(&self, address: &str) -> std::result::Result<(Option<String>, usize), String> {
        let selected: Vec<_> = self
            .wallet
            .lock()
            .unwrap()
            .utxos()
            .into_iter()
            .filter(|u| u.global_index != 0)
            .collect();
        self.sweep_to(selected, address).await
    }

    async fn sweep_to(
        &self,
        mut selected: Vec<fuego_sdk::scanner::UtxoEntry>,
        address: &str,
    ) -> std::result::Result<(Option<String>, usize), String> {
        if selected.is_empty() {
            return Ok((None, 0));
        }
        selected.sort_by(|a, b| b.amount.cmp(&a.amount));
        let remaining = selected.len().saturating_sub(MAX_SWEEP_INPUTS);
        selected.truncate(MAX_SWEEP_INPUTS);
        let total: u64 = selected.iter().map(|u| u.amount).sum();
        let fee = MINIMUM_FEE;
        if total <= fee {
            return Err(format!("balance {total} does not cover the fee {fee}"));
        }
        let decoys = self.fetch_decoys(&selected, DEFAULT_MIXIN).await?;
        let to = fuego_sdk::Address(address.to_string());
        let built = {
            let wallet = self.wallet.lock().unwrap();
            wallet
                .build_with_selection(&selected, &[(to, total - fee)], fee, DEFAULT_MIXIN, &decoys, &mut rand::thread_rng())
                .map_err(|e| format!("build: {e}"))?
        };
        let key_images: Vec<[u8; 32]> = selected.iter().map(|u| u.key_image).collect();
        let tx = self.broadcast_built(built, key_images).await?;
        Ok((Some(tx), remaining))
    }

    /// Persist-before-broadcast + reserve + submit, shared by all send paths.
    /// The full serialized transaction is retained under `txs:<hash>` so
    /// payment proofs can be produced later.
    async fn broadcast_built(
        &self,
        built: fuego_sdk::transaction_builder::BuiltTransaction,
        key_images: Vec<[u8; 32]>,
    ) -> std::result::Result<String, String> {
        let tx_hash_hex = hex::encode(built.tx_hash);
        let serialized_hex = hex::encode(&built.serialized);
        {
            let key = format!("txs:{}", tx_hash_hex);
            let _ = self.db.insert(key.as_bytes(), serialized_hex.as_bytes());
        }

        let mut pending = self.sync_engine().pending();
        pending.push(PendingTx {
            tx_hash: built.tx_hash,
            key_images: key_images.clone(),
            serialized_hex: serialized_hex.clone(),
            created_height: self.wallet.lock().unwrap().height(),
        });
        self.sync_engine().store_pending(&pending);
        {
            let wallet = self.wallet.lock().unwrap();
            wallet.reserve_pending(&key_images);
        }

        let status = self.daemon.send_raw_tx(&serialized_hex).await?;
        match status.as_str() {
            "OK" => {
                log::info!("Transaction {} submitted", tx_hash_hex);
            }
            "Failed" => {
                let mut pending = self.sync_engine().pending();
                pending.retain(|p| p.tx_hash != built.tx_hash);
                self.sync_engine().store_pending(&pending);
                return Err(format!("daemon rejected transaction: {}", status));
            }
            other => {
                log::warn!(
                    "Transaction {} relay status: {} (inputs stay reserved)",
                    tx_hash_hex,
                    other
                );
            }
        }
        Ok(tx_hash_hex)
    }

    /// Decoys for one commitment output: its amount, its asset (the node
    /// filters by term) and never the output itself. A thin pool rings what
    /// there is; consensus sets no floor for commitment rings
    /// (WalletTransactionSender::addAndSignInputs).
    async fn commitment_decoys(
        &self,
        deposit: &CommitmentEntry,
        mixin: usize,
    ) -> std::result::Result<Vec<(u32, [u8; 32])>, String> {
        let entries = self
            .daemon
            .get_random_commitment_outs(deposit.amount, (mixin + 1) as u64, 0, deposit.term)
            .await?;
        let mut seen = std::collections::BTreeSet::new();
        seen.insert(deposit.global_index);
        let mut decoys: Vec<(u32, [u8; 32])> = entries
            .into_iter()
            .filter(|e| seen.insert(e.global_amount_index))
            .map(|e| (e.global_amount_index, e.commit_key))
            .collect();
        decoys.sort_by_key(|(idx, _)| *idx);
        decoys.truncate(mixin);
        Ok(decoys)
    }

    /// XFG key outputs covering `amount`: (selection, total).
    fn select_xfg(&self, amount: u64) -> std::result::Result<(Vec<UtxoEntry>, u64), String> {
        let selected = self
            .wallet
            .lock()
            .unwrap()
            .select_for_send(amount, &mut rand::thread_rng())
            .map_err(|e| format!("coin selection: {e}"))?;
        let found = selected.iter().map(|u| u.amount).sum();
        Ok((selected, found))
    }

    /// Unspent commitment outputs of one asset covering `amount`: HEAT
    /// (HEAT_TERM) or LP shares (DEPOSIT_TERM_LP).
    fn select_commitments(
        &self,
        term: u32,
        amount: u64,
    ) -> std::result::Result<(Vec<CommitmentEntry>, u64), String> {
        let candidates = {
            let wallet = self.wallet.lock().unwrap();
            if term == HEAT_TERM {
                wallet.heat_outputs()
            } else {
                wallet.deposits()
            }
        };
        let mut selected = Vec::new();
        let mut found = 0u64;
        for c in candidates.into_iter().filter(|c| c.term == term && c.global_index != 0) {
            if found >= amount {
                break;
            }
            found += c.amount;
            selected.push(c);
        }
        if found < amount {
            let asset = if term == HEAT_TERM { "HEAT" } else { "LP shares" };
            return Err(format!("insufficient {asset}: need {amount}, have {found}"));
        }
        Ok((selected, found))
    }

    /// What a v11 transaction spends, with decoys: XFG key inputs (sorted by
    /// amount, as the plain send path does), then commitment inputs with the
    /// interest each claims.
    async fn v11_spend(
        &self,
        mut xfg: Vec<UtxoEntry>,
        commitments: Vec<(CommitmentEntry, u64)>,
    ) -> std::result::Result<V11Spend, String> {
        xfg.sort_by_key(|u| u.amount);
        let key_decoys = if xfg.is_empty() {
            Vec::new()
        } else {
            self.fetch_decoys(&xfg, DEFAULT_MIXIN).await?
        };
        let mut commitment_decoys = Vec::with_capacity(commitments.len());
        for (c, _) in &commitments {
            commitment_decoys.push(self.commitment_decoys(c, DEFAULT_MIXIN).await?);
        }
        Ok(V11Spend {
            key_inputs: xfg.iter().map(|u| u.into()).collect(),
            key_decoys,
            commitment_inputs: commitments
                .iter()
                .map(|(c, interest)| CommitmentDeposit {
                    amount: c.amount,
                    commit_key: c.commit_key,
                    key_scalar: c.key_scalar,
                    key_image: c.key_image,
                    global_index: c.global_index,
                    claimed_interest: *interest,
                })
                .collect(),
            commitment_decoys,
        })
    }

    /// Build, sign and broadcast a v11 transaction. Every spent key image
    /// stays reserved until the transaction confirms.
    async fn send_v11(
        &self,
        spend: V11Spend,
        outputs: Vec<V11Output>,
        tag: V11Tag,
        bonus_claims: &[(u8, u64)],
    ) -> std::result::Result<String, String> {
        let keys = self.wallet.lock().unwrap().wallet_keys();
        let built = build_v11_transaction(
            &spend,
            &outputs,
            &tag,
            bonus_claims,
            &keys.view_secret,
            &mut rand::thread_rng(),
        )
        .map_err(|e| format!("build: {e}"))?;
        let mut key_images: Vec<[u8; 32]> = spend.key_inputs.iter().map(|u| u.key_image).collect();
        key_images.extend(spend.commitment_inputs.iter().map(|c| c.key_image));
        self.broadcast_built(built, key_images).await
    }

    /// This wallet's primary address keys.
    fn own_address(&self) -> AddressKeys {
        let keys = self.wallet.lock().unwrap().wallet_keys();
        AddressKeys {
            spend_public: keys.spend_public,
            view_public: keys.view_public,
        }
    }

    /// The CD term range consensus admits (Currency::depositMinTerm/MaxTerm).
    fn deposit_term_range(&self) -> (u32, u32) {
        if self.testnet {
            (TESTNET_DEPOSIT_MIN_TERM, TESTNET_DEPOSIT_MAX_TERM)
        } else {
            (DEPOSIT_MIN_TERM, DEPOSIT_MAX_TERM)
        }
    }

    /// create_afk_lock (WalletLegacy.cpp:2016): a self-transfer locked by
    /// unlock_time, with an Ed25519 adaptor pre-signature over the zero hash
    /// returned out-of-band for the swap counterparty.
    pub async fn create_afk_lock(
        &self,
        amount: u64,
        timeout_hours: u32,
        pair: u8,
    ) -> std::result::Result<(String, String, String, String), String> {
        if amount == 0 {
            return Err("amount must be > 0".into());
        }
        if timeout_hours == 0 || timeout_hours > 200 {
            return Err("timeout_hours must be in 1..=200".into());
        }

        // 1% taker fee folded into the locked amount.
        let fee_bob = amount * SWAP_FEE_RATE_BPS / SWAP_FEE_RATE_DIVISOR;
        let total = amount + fee_bob;
        // Network minimum fee for block major version >= 10 is 8000
        // (CryptoNoteConfig.h MINIMUM_FEE_8KH). 1000-fee lock txs are
        // rejected and never propagate.
        let fee = MINIMUM_FEE;
        let unlock_time = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_secs()
            + (timeout_hours as u64) * 3600;

        // Self-transfer with unlock time, mixin 0 (as the C++ wallet does).
        let own_address = self.primary_address_string();
        let selected = {
            let wallet = self.wallet.lock().unwrap();
            wallet
                .select_for_send(total + fee, &mut rand::thread_rng())
                .map_err(|e| format!("coin selection: {e}"))?
        };
        let decoys: Vec<Vec<DecoyEntry>> = selected.iter().map(|_| Vec::new()).collect();
        let built = {
            let wallet = self.wallet.lock().unwrap();
            wallet
                .build_with_selection_ext(
                    &selected,
                    &[(fuego_sdk::Address(own_address.clone()), total)],
                    fee,
                    0,
                    &decoys,
                    unlock_time,
                    &[],
                    &mut rand::thread_rng(),
                )
                .map_err(|e| format!("build: {e}"))?
        };

        // Adaptor pre-signature material.
        let keys = self.wallet.lock().unwrap().wallet_keys();
        let zero_hash = [0u8; 32];
        let (secret, adaptor_point, pre_sig) = fuego_crypto::ring::generate_afk_lock_data(
            &zero_hash,
            &keys.spend_public,
            &keys.spend_secret,
            &mut rand::thread_rng(),
        )
        .ok_or("adaptor pre-signature generation failed")?;

        // hashLock = H(t): claim() reveals the adaptor secret t as the HTLC
        // preimage, so the hashlock committed here MUST be H(t) — never the
        // adaptor point T = t*G (SwapHashLock.h). SHA-256 for UTXO pairs,
        // keccak256 for Solana/EVM, matching the counterparty programs.
        let hash_lock = afk_hash_lock(pair, &secret);

        let key_images: Vec<[u8; 32]> = selected.iter().map(|u| u.key_image).collect();
        let lock_id = hex::encode(built.tx_hash);
        self.broadcast_built(built, key_images).await?;

        // Keep the AFK secret in memory only (like WalletLegacy
        // m_afkLockSecrets). Persisting t plaintext would let any local
        // reader of wallet_state.sled complete the adaptor signature.
        let afk = AfkLockSecret {
            secret,
            pre_sig: pre_sig.to_vec(),
            amount,
            timeout_hours,
            pair,
        };
        self.afk_secrets
            .lock()
            .unwrap()
            .insert(lock_id.clone(), afk);

        Ok((
            lock_id,
            hex::encode(adaptor_point),
            hex::encode(pre_sig),
            hash_lock,
        ))
    }

    /// mint_heat: burn XFG for HEAT (makeHeatMintV10Request). Consensus prices
    /// a mint at the 8-block TWAP; it is built WALLET_MINT_TWAP_MARGIN_BPS
    /// under it so a TWAP that moves before inclusion does not invalidate it.
    pub async fn mint_heat(&self, xfg_burned: u64) -> std::result::Result<String, String> {
        if xfg_burned == 0 {
            return Err("xfg_burned must be > 0".into());
        }
        let pool = self.daemon.amm_pool().await?;
        if pool.hearth_twap == 0 {
            return Err("no Hearth TWAP yet — HEAT mints open two blocks into v11".into());
        }
        let heat_minted = amm::quote_mint(xfg_burned, pool.hearth_twap);
        let min_heat = if self.testnet {
            amm::TESTNET_HEAT_MINT_MIN_HEAT
        } else {
            amm::HEAT_MINT_MIN_HEAT
        };
        if heat_minted < min_heat {
            return Err(format!("minted HEAT {heat_minted} below minimum {min_heat}"));
        }
        let fee = MINIMUM_FEE;
        let needed = xfg_burned.checked_add(fee).ok_or("amount overflow")?;
        let (xfg, found) = self.select_xfg(needed)?;
        let (outputs, tag) = layout_mint(self.own_address(), xfg_burned, heat_minted, found - needed);
        let spend = self.v11_spend(xfg, Vec::new()).await?;
        self.send_v11(spend, outputs, tag, &[]).await
    }

    /// Hearth AMM swap on the constant-product curve (makeAmmSwapV10Request).
    /// direction 0 sells XFG for HEAT, 1 sells HEAT for XFG. The output is
    /// declared WALLET_SWAP_SLIPPAGE_BPS under the curve's net output;
    /// consensus refuses more than the curve allows or less than `min_output`.
    pub async fn amm_swap(
        &self,
        direction: u8,
        input_amount: u64,
        min_output: u64,
    ) -> std::result::Result<String, String> {
        if input_amount == 0 {
            return Err("input_amount must be > 0".into());
        }
        if direction > 1 {
            return Err("direction must be 0 (XFG->HEAT) or 1 (HEAT->XFG)".into());
        }
        let pool = self.daemon.amm_pool().await?;
        if pool.reserve_xfg == 0 || pool.reserve_heat == 0 {
            return Err("the Hearth pool has no reserves".into());
        }
        let output = amm::quote_swap(direction, input_amount, pool.reserve_xfg, pool.reserve_heat);
        if output == 0 {
            return Err("swap too small for the pool to price".into());
        }
        if output < min_output {
            return Err(format!("expected output {output} is below min_output {min_output}"));
        }
        let fee = MINIMUM_FEE;
        let own = self.own_address();

        if direction == 0 {
            let needed = input_amount.checked_add(fee).ok_or("amount overflow")?;
            let (xfg, found) = self.select_xfg(needed)?;
            let (outputs, tag) =
                layout_swap(own, 0, input_amount, output, min_output, fee, found - needed)
                    .map_err(|e| e.to_string())?;
            let spend = self.v11_spend(xfg, Vec::new()).await?;
            return self.send_v11(spend, outputs, tag, &[]).await;
        }

        // HEAT in, XFG out: the fee comes out of the XFG received.
        if output <= fee {
            return Err(format!("swap output {output} does not cover the fee {fee}"));
        }
        let (heat, found) = self.select_commitments(HEAT_TERM, input_amount)?;
        let (outputs, tag) =
            layout_swap(own, 1, input_amount, output, min_output, fee, found - input_amount)
                .map_err(|e| e.to_string())?;
        let spend = self.v11_spend(Vec::new(), heat.into_iter().map(|c| (c, 0)).collect()).await?;
        self.send_v11(spend, outputs, tag, &[]).await
    }

    /// Hearth LP add (makeLpAddV10Request): a balanced deposit within 1% of
    /// the pool ratio. The shares are declared WALLET_SWAP_SLIPPAGE_BPS under
    /// what the deposit earns; consensus mints exactly what is declared.
    pub async fn lp_add(
        &self,
        amount_xfg: u64,
        amount_heat: u64,
    ) -> std::result::Result<String, String> {
        if amount_xfg == 0 || amount_heat == 0 {
            return Err("both xfg_amount and heat_amount must be > 0".into());
        }
        let pool = self.daemon.amm_pool().await?;
        if pool.reserve_xfg == 0 || pool.reserve_heat == 0 {
            return Err("the Hearth pool has no reserves".into());
        }
        if !amm::deposit_ratio_ok(
            amount_xfg,
            amount_heat,
            pool.reserve_xfg,
            pool.reserve_heat,
            amm::LP_DEPOSIT_RATIO_TOLERANCE_BPS,
        ) {
            return Err(format!(
                "deposit must be within 1% of the pool ratio ({} XFG : {} HEAT atomic)",
                pool.reserve_xfg, pool.reserve_heat
            ));
        }
        let shares = amm::quote_lp_add(
            amount_xfg,
            amount_heat,
            pool.total_lp_shares,
            pool.reserve_xfg,
            pool.reserve_heat,
        );
        if shares == 0 {
            return Err("the deposit earns no LP shares".into());
        }
        let fee = MINIMUM_FEE;
        let needed_xfg = amount_xfg.checked_add(fee).ok_or("amount overflow")?;
        let (xfg, found_xfg) = self.select_xfg(needed_xfg)?;
        let (heat, found_heat) = self.select_commitments(HEAT_TERM, amount_heat)?;
        let (outputs, tag) = layout_lp_add(
            self.own_address(),
            amount_xfg,
            amount_heat,
            shares,
            found_heat - amount_heat,
            found_xfg - needed_xfg,
        );
        let spend = self.v11_spend(xfg, heat.into_iter().map(|c| (c, 0)).collect()).await?;
        self.send_v11(spend, outputs, tag, &[]).await
    }

    /// Hearth LP removal (makeLpRemoveV10Request). The pool pays exactly what
    /// the transaction declares: the shares' pro-rata claim,
    /// WALLET_SWAP_SLIPPAGE_BPS under it. The XFG payout carries the fee;
    /// shares selected beyond those burned come back as a smaller position.
    pub async fn lp_remove(
        &self,
        lp_shares: u64,
        min_xfg: u64,
        min_heat: u64,
    ) -> std::result::Result<String, String> {
        if lp_shares == 0 {
            return Err("shares must be > 0".into());
        }
        let pool = self.daemon.amm_pool().await?;
        if pool.total_lp_shares < lp_shares {
            return Err(format!(
                "the pool has {} LP shares in all, fewer than {lp_shares}",
                pool.total_lp_shares
            ));
        }
        let (pay_xfg, pay_heat) = amm::quote_lp_remove(
            lp_shares,
            pool.total_lp_shares,
            pool.reserve_xfg,
            pool.reserve_heat,
        );
        let fee = MINIMUM_FEE;
        if pay_xfg <= fee {
            return Err(format!("the XFG payout {pay_xfg} does not cover the fee {fee}"));
        }
        if pay_xfg < min_xfg || pay_heat < min_heat {
            return Err(format!(
                "payout {pay_xfg} XFG / {pay_heat} HEAT is below the minimum {min_xfg} / {min_heat}"
            ));
        }
        let (lp, found) = self.select_commitments(DEPOSIT_TERM_LP, lp_shares)?;
        let (outputs, tag) =
            layout_lp_remove(self.own_address(), lp_shares, pay_xfg, pay_heat, fee, found - lp_shares)
                .map_err(|e| e.to_string())?;
        let spend = self.v11_spend(Vec::new(), lp.into_iter().map(|c| (c, 0)).collect()).await?;
        self.send_v11(spend, outputs, tag, &[]).await
    }

    /// Hearth limit order (makePlaceOrderV13Request). Side 1 sells XFG and
    /// escrows XFG; side 0 buys XFG and escrows HEAT; XFG pays the fee. The
    /// order lives `ttl_blocks` blocks — consensus reads the expiration as an
    /// absolute height. Returns (tx hash, order id); the id withdraws it.
    pub async fn place_limit_order(
        &self,
        side: u8,
        amount: u64,
        target_price: u64,
        ttl_blocks: u32,
    ) -> std::result::Result<(String, String), String> {
        if amount == 0 {
            return Err("amount must be > 0".into());
        }
        if side > 1 {
            return Err("side must be 0 (BUY) or 1 (SELL)".into());
        }
        if target_price == 0 || target_price % amm::ORDER_PRICE_TICK != 0 {
            return Err(format!(
                "price must be a positive multiple of the price tick ({} atomic)",
                amm::ORDER_PRICE_TICK
            ));
        }
        if ttl_blocks == 0 || ttl_blocks > ORDERBOOK_MAX_ENDURANCE {
            return Err(format!("an order lives 1..={ORDERBOOK_MAX_ENDURANCE} blocks"));
        }
        let height = self.daemon.get_height().await?;
        let expiration = u32::try_from(height + ttl_blocks as u64)
            .map_err(|_| "expiration height out of range".to_string())?;

        let fee = MINIMUM_FEE;
        let (heat, heat_change) = if side == 0 {
            let (heat, found) = self.select_commitments(HEAT_TERM, amount)?;
            (heat, found - amount)
        } else {
            (Vec::new(), 0)
        };
        let xfg_needed = if side == 1 {
            amount.checked_add(fee).ok_or("amount overflow")?
        } else {
            fee
        };
        let (xfg, found) = self.select_xfg(xfg_needed)?;

        let mut order_id = [0u8; 32];
        rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut order_id);
        let (outputs, tag) = layout_place_order(
            self.own_address(),
            side,
            amount,
            target_price,
            expiration,
            order_id,
            heat_change,
            found - xfg_needed,
        )
        .map_err(|e| e.to_string())?;
        let spend = self.v11_spend(xfg, heat.into_iter().map(|c| (c, 0)).collect()).await?;
        let tx = self.send_v11(spend, outputs, tag, &[]).await?;
        Ok((tx, hex::encode(order_id)))
    }

    /// Withdraw a limit order (makeCancelOrderV13Request): its remaining
    /// escrow and every fill's proceeds leave together, proven by this
    /// wallet's spend key over the outputs. An expired order is withdrawn the
    /// same way.
    pub async fn cancel_limit_order(&self, order_id_hex: &str) -> std::result::Result<String, String> {
        let order_id: [u8; 32] = hex::decode(order_id_hex)
            .map_err(|_| "invalid order_id".to_string())?
            .try_into()
            .map_err(|_| "invalid order_id length".to_string())?;
        let orders = self.daemon.limit_orders().await?;
        let order = orders
            .iter()
            .find(|o| o.order_id.eq_ignore_ascii_case(order_id_hex))
            .ok_or("limit order does not exist")?;
        if order.withdrawn {
            return Err("limit order already withdrawn".into());
        }
        let own = self.own_address();
        if !order.address_hash.eq_ignore_ascii_case(&hex::encode(address_hash(&own))) {
            return Err("limit order belongs to another wallet".into());
        }
        let (pay_xfg, pay_heat) = if order.side == 1 {
            (order.amount, order.proceeds_heat)
        } else {
            (order.proceeds_xfg, order.amount)
        };
        if pay_xfg == 0 && pay_heat == 0 {
            return Err("limit order holds nothing to withdraw".into());
        }
        let fee = MINIMUM_FEE;
        let (xfg, found) = self.select_xfg(fee)?;
        let spend_secret = self.wallet.lock().unwrap().wallet_keys().spend_secret;
        let (outputs, tag) =
            layout_cancel_order(own, spend_secret, order_id, pay_xfg, pay_heat, found - fee);
        let spend = self.v11_spend(xfg, Vec::new()).await?;
        self.send_v11(spend, outputs, tag, &[]).await
    }

    /// A HEAT CD (makeHeatDepositV10Request): HEAT funds the CD and its 0.1%
    /// banking fee, burned to the Treasury LP Manager (TreasuryFund, asset 1);
    /// XFG pays the network fee.
    async fn heat_cd_core(
        &self,
        amount: u64,
        term_blocks: u32,
        banking_fee: u64,
    ) -> std::result::Result<String, String> {
        if amount == 0 {
            return Err("amount must be > 0".into());
        }
        let (min_term, max_term) = self.deposit_term_range();
        if term_blocks < min_term || term_blocks > max_term {
            return Err(format!("term must be in {min_term}..={max_term} blocks"));
        }
        let banking_fee = if banking_fee == 0 {
            (amount / 1000).max(1)
        } else {
            banking_fee
        };
        let needed_heat = amount.checked_add(banking_fee).ok_or("amount overflow")?;
        let fee = MINIMUM_FEE;
        let (heat, found_heat) = self.select_commitments(HEAT_TERM, needed_heat)?;
        let (xfg, found_xfg) = self.select_xfg(fee)?;
        let (outputs, tag) = layout_cd_create(
            self.own_address(),
            amount,
            term_blocks,
            banking_fee,
            found_heat - needed_heat,
            found_xfg - fee,
        );
        let spend = self.v11_spend(xfg, heat.into_iter().map(|c| (c, 0)).collect()).await?;
        self.send_v11(spend, outputs, tag, &[]).await
    }

    /// create_cd: a HEAT CD with its term in blocks (the GUI passes
    /// duration_blocks), within the network's CD term range.
    pub async fn create_cd(
        &self,
        amount: u64,
        term_blocks: u32,
    ) -> std::result::Result<String, String> {
        self.heat_cd_core(amount, term_blocks, 0).await
    }

    /// heat_cd: a HEAT CD with its term in epochs (CLI-style).
    pub async fn heat_cd(
        &self,
        amount: u64,
        epochs: u32,
        banking_fee: u64,
    ) -> std::result::Result<String, String> {
        if epochs == 0 {
            return Err("epochs must be > 0".into());
        }
        let epoch_blocks: u64 = if self.testnet { 10 } else { 900 };
        let term_blocks = u32::try_from(epochs as u64 * epoch_blocks)
            .map_err(|_| "term out of range".to_string())?;
        self.heat_cd_core(amount, term_blocks, banking_fee).await
    }

    /// Per CD: (claimed interest = base + bonus, bonus), as
    /// makeWithdrawDepositRequest computes them — what the node says has
    /// accrued, scaled down when the CD yield pool or the Bonus Vault cannot
    /// back it all. A node that cannot say stops the withdrawal: interest left
    /// off is lost with the key image.
    async fn cd_claims(
        &self,
        deposits: &[CommitmentEntry],
        current_height: u32,
    ) -> std::result::Result<(Vec<u64>, Vec<u64>), String> {
        let mut base = vec![0u64; deposits.len()];
        let mut bonus = vec![0u64; deposits.len()];
        let (mut pool_available, mut bonus_available) = (u64::MAX, u64::MAX);
        for (i, d) in deposits.iter().enumerate() {
            let info = self
                .daemon
                .cd_claim_info(d.amount, d.block_height as u32, current_height, d.term)
                .await
                .map_err(|e| {
                    format!(
                        "cannot read a CD's accrued interest from the node ({e}); withdrawal \
                         aborted so the interest is not forfeited"
                    )
                })?;
            if info.formula_interest == 0 {
                continue;
            }
            if info.pool_info_present {
                pool_available = pool_available.min(info.fee_pool_balance.min(info.vault_balance));
                bonus_available = bonus_available.min(info.bonus_vault_balance);
            }
            if info.base_interest > 0 || info.bonus_interest > 0 {
                base[i] = info.base_interest;
                bonus[i] = info.claimable_bonus;
            } else {
                base[i] = info.formula_interest;
            }
        }
        scale_claims(&mut base, pool_available);
        scale_claims(&mut bonus, bonus_available);
        let claims = base.iter().zip(&bonus).map(|(b, x)| b + x).collect();
        Ok((claims, bonus))
    }

    /// Matured CDs (not markers), by the chain tip.
    async fn matured_cds(&self) -> std::result::Result<(Vec<CommitmentEntry>, u64), String> {
        let tip = self.daemon.get_height().await?.saturating_sub(1);
        let cds = self
            .wallet
            .lock()
            .unwrap()
            .deposits()
            .into_iter()
            .filter(|d| {
                !is_marker_term(d.term) && d.global_index != 0 && d.block_height + d.term as u64 <= tip
            })
            .collect();
        Ok((cds, tip))
    }

    /// claim_cd: withdraw every matured CD (makeWithdrawDepositRequest).
    /// Principal and interest come back as HEAT; XFG pays the fee; each CD's
    /// Bonus-Vault share is declared per input.
    pub async fn claim_cd(&self) -> std::result::Result<String, String> {
        let (deposits, tip) = self.matured_cds().await?;
        if deposits.is_empty() {
            return Err("no mature CDs to claim".into());
        }
        if deposits.len() > 200 {
            return Err("too many CDs for one withdrawal; claim them in batches".into());
        }
        let (claims, bonus) = self.cd_claims(&deposits, tip as u32).await?;
        let mut payout = 0u64;
        for (d, claim) in deposits.iter().zip(&claims) {
            payout = payout
                .checked_add(d.amount)
                .and_then(|p| p.checked_add(*claim))
                .ok_or("payout overflow")?;
        }
        let fee = MINIMUM_FEE;
        let (xfg, found) = self.select_xfg(fee)?;
        let key_inputs = xfg.len();
        let bonus_claims = bonus_claims_for(key_inputs, &bonus)?;
        let (outputs, tag) = layout_cd_withdraw(self.own_address(), payout, found - fee);
        let spend = self.v11_spend(xfg, deposits.into_iter().zip(claims).collect()).await?;
        self.send_v11(spend, outputs, tag, &bonus_claims).await
    }

    /// rollover_cd: a matured CD, principal and interest, into a new CD.
    /// `new_term` is in blocks; 0 keeps the original term. HEAT in (principal
    /// plus claimed interest) equals HEAT out; XFG pays the fee.
    pub async fn rollover_cd(
        &self,
        cd_id: &str,
        new_term: u32,
    ) -> std::result::Result<String, String> {
        let want: [u8; 32] = hex::decode(cd_id)
            .map_err(|_| "invalid cd_id".to_string())?
            .try_into()
            .map_err(|_| "invalid cd_id length".to_string())?;
        let (matured, tip) = self.matured_cds().await?;
        let deposit = matured
            .into_iter()
            .find(|d| d.tx_hash == want)
            .ok_or("CD not found, not yet mature, or already spent")?;
        let term = if new_term == 0 { deposit.term } else { new_term };
        let (min_term, max_term) = self.deposit_term_range();
        if term < min_term || term > max_term {
            return Err(format!("new term must be in {min_term}..={max_term} blocks"));
        }
        let (claims, bonus) = self.cd_claims(std::slice::from_ref(&deposit), tip as u32).await?;
        let rolled = deposit.amount.checked_add(claims[0]).ok_or("amount overflow")?;
        let fee = MINIMUM_FEE;
        let (xfg, found) = self.select_xfg(fee)?;
        let bonus_claims = bonus_claims_for(xfg.len(), &bonus)?;
        let (outputs, tag) = layout_cd_rollover(self.own_address(), rolled, term, found - fee);
        let spend = self.v11_spend(xfg, vec![(deposit, claims[0])]).await?;
        self.send_v11(spend, outputs, tag, &bonus_claims).await
    }

    /// send_heat (makeHeatTransferV10Request): HEAT owner-bound to the
    /// recipient's spend key — only it can spend the output. HEAT balances
    /// exactly; XFG pays the fee.
    pub async fn send_heat(
        &self,
        address: &str,
        amount: u64,
    ) -> std::result::Result<String, String> {
        if amount == 0 {
            return Err("amount must be > 0".into());
        }
        let (recv_spend, recv_view) = fuego_crypto::parse_address(address)
            .ok_or_else(|| format!("invalid destination address: {}", address))?;
        let recipient = AddressKeys {
            spend_public: recv_spend,
            view_public: recv_view,
        };
        let fee = MINIMUM_FEE;
        let (heat, found_heat) = self.select_commitments(HEAT_TERM, amount)?;
        let (xfg, found_xfg) = self.select_xfg(fee)?;
        let (outputs, tag) = layout_heat_send(
            self.own_address(),
            recipient,
            amount,
            found_heat - amount,
            found_xfg - fee,
        );
        let spend = self.v11_spend(xfg, heat.into_iter().map(|c| (c, 0)).collect()).await?;
        self.send_v11(spend, outputs, tag, &[]).await
    }

    /// get_tx_proof: a "ProofV1" payment proof for one of our outgoing
    /// transactions (WalletLegacy::getTxProof format: "ProofV1" +
    /// base58(r*A) + base58(sig), with the tx hash as the message).
    pub async fn get_tx_proof(
        &self,
        tx_hash: &str,
        address: &str,
    ) -> std::result::Result<String, String> {
        let (recv_spend, recv_view) = fuego_crypto::parse_address(address)
            .ok_or_else(|| format!("invalid address: {}", address))?;
        let _ = &recv_spend;

        let key = format!("txs:{}", tx_hash);
        let serialized_hex = self
            .db
            .get(key.as_bytes())
            .ok()
            .flatten()
            .map(|b| String::from_utf8_lossy(&b).to_string())
            .ok_or_else(|| format!("transaction {} not found (only locally-sent txs are provable)", tx_hash))?;
        let serialized = hex::decode(&serialized_hex)
            .map_err(|e| format!("stored tx decode failed: {e}"))?;
        let prefix = fuego_sdk::serialization::parse_prefix(&serialized)
            .map_err(|e| format!("stored tx parse failed: {e}"))?;

        // Recover the deterministic tx secret key.
        let keys = self.wallet.lock().unwrap().wallet_keys();
        let r = fuego_sdk::transaction_builder::recover_tx_secret(&prefix.inputs, &keys.view_secret);

        // R = r*G; D = r*A (raw, no cofactor).
        let mut r_p3 = fuego_crypto::ref10::GeP3::default();
        fuego_crypto::ref10::ge_scalarmult_base(&mut r_p3, &r);
        let mut r_pub = [0u8; 32];
        fuego_crypto::ref10::ge_p3_tobytes(&mut r_pub, &r_p3);
        let d = fuego_crypto::ring::raw_scalarmult_key(&recv_view, &r)
            .ok_or("tx proof derivation failed")?;

        let prefix_hash =
            fuego_crypto::cn_fast_hash(&fuego_sdk::serialization::serialize_prefix(&prefix));
        let sig = fuego_crypto::ring::generate_tx_proof(
            &prefix_hash,
            &r,
            &r_pub,
            &recv_view,
            &d,
            &mut rand::thread_rng(),
        )
        .ok_or("tx proof generation failed")?;

        let mut out = String::from("ProofV1");
        out.push_str(&fuego_crypto::cn_base58_encode(&d));
        out.push_str(&fuego_crypto::cn_base58_encode(&sig));
        Ok(out)
    }

    // ------------------------------------------------------------ API

    pub async fn address(&self) -> String {
        self.primary_address_string()
    }

    pub async fn balance(&self) -> u64 {
        self.wallet.lock().unwrap().balance().confirmed
    }

    pub async fn height(&self) -> u64 {
        self.wallet.lock().unwrap().height()
    }

    pub async fn balance_full(&self) -> Balance {
        self.wallet.lock().unwrap().balance()
    }

    pub fn sync_status(&self) -> SyncStatus {
        SyncStatus {
            current_height: self.wallet.lock().unwrap().height(),
            target_height: 0,
            is_syncing: false,
            last_sync_time: None,
        }
    }

    pub async fn get_transactions(&self, limit: usize) -> Vec<fuego_sdk::scanner::HistoryEntry> {
        self.wallet.lock().unwrap().get_transactions(limit)
    }

    pub async fn get_keypair(&self, index: u32) -> Keypair {
        self.wallet.lock().unwrap().get_keypair(index)
    }

    pub async fn register_alias(&self, _alias: &str, _fee: u64) -> Result<[u8; 32]> {
        Err(SdkError::Vault(
            "alias registration is not part of the transaction builder path (Phase 7)".into(),
        ))
    }

    pub async fn claim_afk_swap(
        &self,
        lock_id: &str,
        payout_address: &str,
        _taker_signature_hex: &str,
    ) -> Result<[u8; 32]> {
        let mut secret = self
            .afk_secrets
            .lock()
            .unwrap()
            .remove(lock_id)
            .ok_or_else(|| SdkError::Vault(format!("no AFK lock secret for {}", lock_id)))?;

        let total_locked = secret.amount + secret.amount * SWAP_FEE_RATE_BPS / SWAP_FEE_RATE_DIVISOR;
        let taker_net = secret.amount - secret.amount * SWAP_FEE_RATE_BPS / SWAP_FEE_RATE_DIVISOR;
        let taker_gross = taker_net + MINIMUM_FEE;
        let fee_pool_amount = total_locked.saturating_sub(taker_gross + MINIMUM_FEE);

        let mut dests: Vec<(String, u64)> = vec![(payout_address.to_string(), taker_gross)];
        if fee_pool_amount > 0 {
            if let Ok(info) = self.daemon.get_info().await {
                if !info.fee_address.is_empty() {
                    dests.push((info.fee_address, fee_pool_amount));
                }
            }
        }
        let tx_hash = self
            .send_transaction(&dests, MINIMUM_FEE, DEFAULT_MIXIN as u32)
            .await
            .map_err(SdkError::Vault)?;
        // Zeroize the adaptor secret now that it has been used.
        secret.secret.iter_mut().for_each(|b| *b = 0);
        secret.pre_sig.iter_mut().for_each(|b| *b = 0);
        let bytes = hex::decode(&tx_hash).map_err(|e| SdkError::Vault(e.to_string()))?;
        if bytes.len() != 32 {
            return Err(SdkError::Vault("unexpected tx hash length".into()));
        }
        let mut out = [0u8; 32];
        out.copy_from_slice(&bytes);
        Ok(out)
    }

    /// list_cds: rich CD objects matching the GUI model. The deposit list is
    /// derived from the local scanner state (finite-term HEAT commitments).
    /// Each entry reports ownership, term/maturity in blocks, and accrued
    /// interest estimated by the daemon (estimate_cd_yield), with a display
    /// friendly amount in HEAT atomic-to-decimal form.
    pub async fn list_cds(&self) -> Vec<serde_json::Value> {
        let height = self.wallet.lock().unwrap().height();
        let owner = self.address().await;
        let deposits: Vec<fuego_sdk::scanner::CommitmentEntry> = self
            .wallet
            .lock()
            .unwrap()
            .deposits()
            .into_iter()
            .filter(|d| d.global_index != 0)
            .collect();

        let mut out = Vec::with_capacity(deposits.len());
        for d in deposits {
            let maturity_height = d.block_height.saturating_add(d.term as u64);
            let blocks_to_maturity = maturity_height.saturating_sub(height);
            let matured = blocks_to_maturity == 0 && height >= maturity_height;
            let interest = self
                .daemon
                .estimate_cd_yield(d.amount, d.block_height as u32)
                .await
                .unwrap_or(0);
            let total = d.amount.saturating_add(interest);
            let rate_pct = if d.amount > 0 {
                interest as f64 / d.amount as f64 * 100.0
            } else {
                0.0
            };
            out.push(serde_json::json!({
                "cd_id": hex::encode(d.tx_hash),
                "owner": owner,
                "coin": "HEAT",
                "amount": Self::display_heat(d.amount),
                "interest_rate": format!("{:.2}", rate_pct),
                "maturity_height": maturity_height,
                "deposit_height": d.block_height,
                "accrued_interest": Self::display_heat(interest),
                "total_value": Self::display_heat(total),
                "blocks_to_maturity": blocks_to_maturity,
                "matured": matured,
                "for_sale": false,
            }));
        }
        out
    }

    /// Format an atomic HEAT amount as a human HEAT decimal (max 7 dp).
    fn display_heat(atomic: u64) -> String {
        let whole = atomic / COIN;
        let frac = atomic % COIN;
        if frac == 0 {
            return whole.to_string();
        }
        format!("{}.{:07}", whole, frac).trim_end_matches('0').to_string()
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    /// t = 0x00..0x1f (32 bytes). Pinned digests computed independently:
    /// sha256(t)  = 630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd
    /// keccak(t)  = 8ae1aa597fa146ebd3aa2ceddf360668dea5e526567e92b0321816a4e895bd2d
    const T: [u8; 32] = [
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c,
        0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19,
        0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    ];

    #[test]
    fn hashlock_is_hash_of_secret_not_point() {
        // UTXO pairs use sha256(t).
        for pair in [3u8, 6, 8, 9, 10] {
            assert_eq!(
                afk_hash_lock(pair, &T),
                "630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd"
            );
        }
        // SOL/ETH family use keccak256(t).
        for pair in [0u8, 1, 4, 5, 7, 11] {
            assert_eq!(
                afk_hash_lock(pair, &T),
                "8ae1aa597fa146ebd3aa2ceddf360668dea5e526567e92b0321816a4e895bd2d"
            );
        }
    }

    #[test]
    fn hashlock_never_equals_hash_of_adaptor_point() {
        // T_point = t*G must never be the hashlock input (the original bug).
        let mut p3 = fuego_crypto::ref10::GeP3::default();
        fuego_crypto::ref10::ge_scalarmult_base(&mut p3, &T);
        let mut point = [0u8; 32];
        fuego_crypto::ref10::ge_p3_tobytes(&mut point, &p3);
        let h_point_sha = {
            use sha2::Digest;
            hex::encode(sha2::Sha256::digest(point))
        };
        let h_point_keccak = hex::encode(fuego_crypto::cn_fast_hash(&point));
        let lock_sha = afk_hash_lock(9, &T);
        let lock_keccak = afk_hash_lock(0, &T);
        assert_ne!(lock_sha, h_point_sha);
        assert_ne!(lock_keccak, h_point_keccak);
        assert_ne!(lock_sha, lock_keccak);
    }
}

#[cfg(test)]
mod subaddress_service_tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "fuego-walletd-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn subaddresses_follow_suite_scheme_and_persist() {
        let dir = temp_dir("sub");
        let seed = [0x42u8; 32];
        {
            let svc = WalletService::new(seed, "http://127.0.0.1:1", dir.clone(), false).unwrap();
            let (i1, a1) = svc.create_subaddress().unwrap();
            let (i2, _) = svc.create_subaddress().unwrap();
            assert_eq!((i1, i2), (1, 2));

            let keys = svc.wallet.lock().unwrap().wallet_keys();
            let (spend, view) = fuego_crypto::parse_address(&a1).unwrap();
            let expect = fuego_crypto::derive_subaddress_keys(&keys.view_secret, &keys.spend_public, None, 0, 1).unwrap();
            assert_eq!(spend, expect.spend_public);
            assert_eq!(view, keys.view_public);
        }
        // Restart: the count survives, so indices keep increasing.
        let svc = WalletService::new(seed, "http://127.0.0.1:1", dir.clone(), false).unwrap();
        assert_eq!(svc.create_subaddress().unwrap().0, 3);
        let (subs, legacy) = svc.list_subaddresses();
        assert_eq!(subs.iter().map(|s| s.0).collect::<Vec<_>>(), vec![1, 2, 3]);
        assert!(legacy.is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn legacy_registration_schedules_one_rescan() {
        let dir = temp_dir("legacy");
        let svc = WalletService::new([7u8; 32], "http://127.0.0.1:1", dir.clone(), false).unwrap();
        assert!(!matches!(svc.db.get(KEY_RESCAN), Ok(Some(_))), "fresh wallet: nothing to rescan");
        assert!(svc.register_legacy_subaddresses(&[1, 2]));
        assert!(matches!(svc.db.get(KEY_RESCAN), Ok(Some(_))));
        let _ = svc.db.remove(KEY_RESCAN);
        assert!(!svc.register_legacy_subaddresses(&[2, 1]), "already known");
        assert!(!matches!(svc.db.get(KEY_RESCAN), Ok(Some(_))));
        drop(svc);
        // Legacy indices survive a restart.
        let svc = WalletService::new([7u8; 32], "http://127.0.0.1:1", dir.clone(), false).unwrap();
        assert_eq!(svc.list_subaddresses().1.iter().map(|l| l.0).collect::<Vec<_>>(), vec![1, 2]);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn height_and_top_hash_are_stored_together() {
        let dir = temp_dir("persist");
        {
            let svc = WalletService::new([8u8; 32], "http://127.0.0.1:1", dir.clone(), false).unwrap();
            let engine = svc.sync_engine();
            // What sync_once does per block: advance both in memory, nothing on disk yet.
            {
                let wallet = svc.wallet.lock().unwrap();
                wallet.set_height(77);
                *svc.top.lock().unwrap() = Some([0xabu8; 32]);
            }
            assert!(svc.db.get(KEY_TOP_HASH).unwrap().is_none(), "hash not written ahead of the state");
            engine.persist_state();
        }
        let svc = WalletService::new([8u8; 32], "http://127.0.0.1:1", dir.clone(), false).unwrap();
        assert_eq!(svc.wallet.lock().unwrap().height(), 77);
        assert_eq!(svc.sync_engine().top_hash(), Some([0xabu8; 32]));

        svc.sync_engine().start_rescan();
        assert_eq!(svc.sync_engine().top_hash(), None);
        assert!(svc.db.get(KEY_TOP_HASH).unwrap().is_none());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn state_from_older_scan_rules_is_rescanned() {
        let dir = temp_dir("upgrade");
        {
            let svc = WalletService::new([9u8; 32], "http://127.0.0.1:1", dir.clone(), false).unwrap();
            // Simulate state written by an older walletd: scanned height, no version.
            svc.wallet.lock().unwrap().set_height(1234);
            svc.sync_engine().persist_state();
            let _ = svc.db.remove(KEY_SCAN_VERSION);
            let _ = svc.db.flush();
        }
        let svc = WalletService::new([9u8; 32], "http://127.0.0.1:1", dir.clone(), false).unwrap();
        assert!(matches!(svc.db.get(KEY_RESCAN), Ok(Some(_))));
        svc.sync_engine().start_rescan();
        assert_eq!(svc.wallet.lock().unwrap().height(), 0);
        let _ = std::fs::remove_dir_all(dir);
    }
}
