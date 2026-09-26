use crate::daemon::DaemonClient;

use fuego_sdk::*;
use fuego_sdk::serialization::{add_treasury_fund_extra, HEAT_TERM};
use fuego_sdk::transaction_builder::{
    build_commitment_spend_transaction, decompose_change, BuildCommitmentDestination,
    BuildDestination, CommitmentDeposit, DecoyEntry, DEFAULT_DUST_THRESHOLD, MINIMUM_FEE,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

/// Default ring size when the caller does not specify one (C++ API default
/// mixIn is 4).
const DEFAULT_MIXIN: usize = 4;
/// CryptoNoteConfig.h SWAP_FEE_RATE_BPS / SWAP_FEE_RATE_DIVISOR (AFK taker fee).
const SWAP_FEE_RATE_BPS: u64 = 100;
const SWAP_FEE_RATE_DIVISOR: u64 = 10000;
/// Atomic units per coin (CryptoNoteConfig.h COIN).
const COIN: u64 = 10_000_000;
/// CryptoNoteConfig.h DEPOSIT_MIN_TERM / DEPOSIT_MAX_TERM (blocks).
const DEPOSIT_MIN_TERM: u32 = 5400;
const DEPOSIT_MAX_TERM: u32 = 64800;
/// CryptoNoteConfig.h HEAT_MINT_MIN_HEAT (0.1 HEAT).
const HEAT_MINT_MIN_HEAT: u64 = 1_000_000;

/// Integer square root (AmmPool.cpp isqrt128).
fn isqrt128(n: u128) -> u64 {
    if n <= 1 {
        return n as u64;
    }
    let mut x: u128 = n;
    let mut y: u128 = (x + 1) >> 1;
    while y < x {
        x = y;
        y = (x + n / x) >> 1;
    }
    x as u64
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

fn db_get<T: serde::de::DeserializeOwned>(db: &sled::Db, key: &[u8]) -> Option<T> {
    db.get(key).ok().flatten().and_then(|b| bincode::deserialize::<T>(&b).ok())
}

fn db_put<T: serde::Serialize>(db: &sled::Db, key: &[u8], value: &T) {
    let _ = bincode::serialize(value).ok().and_then(|b| db.insert(key, b).ok());
}

fn meta_tree(db: &sled::Db) -> sled::Tree {
    db.open_tree("meta").expect("open meta tree")
}

impl WalletService {
    pub fn new(seed: [u8; 32], daemon_url: &str, wallet_dir: PathBuf, testnet: bool) -> Result<Self> {
        let wallet = Arc::new(Mutex::new(Wallet::from_seed(seed)?));
        let daemon = DaemonClient::new(daemon_url);
        let db = sled::open(wallet_dir.join("wallet_state.sled"))
            .map_err(|e| SdkError::Storage(format!("sled open: {e}")))?;

        let service = Self {
            wallet,
            daemon,
            db,
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

    fn persist_state(&self) {
        let wallet = self.wallet.lock().unwrap();
        let snapshot = wallet.snapshot_state();
        let db = &self.db;
        let _ = bincode::serialize(&snapshot.height).ok().and_then(|b| db.insert(KEY_HEIGHT, b).ok());
        let _ = bincode::serialize(&snapshot.utxos).ok().and_then(|b| db.insert(b"utxos", b).ok());
        let _ = bincode::serialize(&snapshot.commitments).ok().and_then(|b| db.insert(b"commitments", b).ok());
        let _ = bincode::serialize(&snapshot.spent_images).ok().and_then(|b| db.insert(b"spent", b).ok());
        let _ = bincode::serialize(&snapshot.history).ok().and_then(|b| db.insert(b"history", b).ok());
        db_put(db, KEY_OWNERS, &snapshot.owners);
        if let Ok(Some(bytes)) = db.get(KEY_TOP_HASH) {
            let _ = db.flush();
            let _ = bytes;
        } else {
            let _ = db.flush();
        }
    }

    fn top_hash(&self) -> Option<[u8; 32]> {
        self.db
            .get(KEY_TOP_HASH)
            .ok()
            .flatten()
            .and_then(|b| bincode::deserialize::<[u8; 32]>(&b).ok())
    }

    fn set_top_hash(&self, hash: &[u8; 32]) {
        let _ = bincode::serialize(hash).ok().and_then(|b| self.db.insert(KEY_TOP_HASH, b).ok());
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
            drop(wallet);
            self.set_top_hash(&item.block_id);
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
        }
        let _ = self.db.remove(KEY_TOP_HASH);
        let _ = self.db.remove(KEY_RESCAN);
        self.persist_state();
        log::info!("rescanning from genesis");
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
        if selected.is_empty() {
            return Ok(None);
        }
        let total: u64 = selected.iter().map(|u| u.amount).sum();
        let fee = MINIMUM_FEE;
        if total <= fee {
            return Err(format!("legacy balance {total} does not cover the fee {fee}"));
        }
        let decoys = self.fetch_decoys(&selected, DEFAULT_MIXIN).await?;
        let own = fuego_sdk::Address(self.primary_address_string());
        let built = {
            let wallet = self.wallet.lock().unwrap();
            wallet
                .build_with_selection(&selected, &[(own, total - fee)], fee, DEFAULT_MIXIN, &decoys, &mut rand::thread_rng())
                .map_err(|e| format!("build: {e}"))?
        };
        let key_images: Vec<[u8; 32]> = selected.iter().map(|u| u.key_image).collect();
        self.broadcast_built(built, key_images).await.map(Some)
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

    /// Fetch decoy commitment outputs for one deposit.
    async fn commitment_decoys(
        &self,
        deposit: &fuego_sdk::scanner::CommitmentEntry,
        mixin: usize,
    ) -> std::result::Result<Vec<(u32, [u8; 32])>, String> {
        let entries = self
            .daemon
            .get_random_commitment_outs(deposit.amount, (mixin + 1) as u64, 0)
            .await?;
        let mut decoys: Vec<(u32, [u8; 32])> = entries
            .into_iter()
            .filter(|e| e.global_amount_index != deposit.global_index)
            .map(|e| (e.global_amount_index, e.commit_key))
            .collect();
        decoys.sort_by_key(|(idx, _)| *idx);
        decoys.truncate(mixin);
        if decoys.len() < mixin {
            return Err(format!(
                "MIXIN_COUNT_TOO_BIG: only {} commitment decoys available for amount {} (requested {})",
                decoys.len(),
                deposit.amount,
                mixin
            ));
        }
        Ok(decoys)
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

    /// mint_heat: burn XFG, mint HEAT at the Hearth pool spot price.
    pub async fn mint_heat(&self, xfg_burned: u64) -> std::result::Result<String, String> {
        if xfg_burned == 0 {
            return Err("xfg_burned must be > 0".into());
        }
        let (_rx, _rh, spot_price) = self.daemon.amm_pool_info().await?;
        if spot_price == 0 {
            return Err("no pool price available".into());
        }
        let heat_minted = (xfg_burned as u128 * spot_price as u128 / COIN as u128) as u64;
        if heat_minted < HEAT_MINT_MIN_HEAT {
            return Err(format!(
                "minted HEAT {} below minimum {}",
                heat_minted, HEAT_MINT_MIN_HEAT
            ));
        }

        let fee = MINIMUM_FEE;
        let keys = self.wallet.lock().unwrap().wallet_keys();
        let selected = {
            let wallet = self.wallet.lock().unwrap();
            wallet
                .select_for_send(xfg_burned + fee, &mut rand::thread_rng())
                .map_err(|e| format!("coin selection: {e}"))?
        };
        let found: u64 = selected.iter().map(|u| u.amount).sum();
        let change = found - xfg_burned - fee;

        let mixin = DEFAULT_MIXIN;
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
            if entries.len() < mixin {
                return Err(format!(
                    "MIXIN_COUNT_TOO_BIG: only {} decoys available for amount {}",
                    entries.len(),
                    utxo.amount
                ));
            }
            decoys.push(entries);
        }

        let inputs: Vec<fuego_sdk::transaction_builder::SpendableOutput> =
            selected.iter().map(|u| u.into()).collect();
        let built = fuego_sdk::transaction_builder::build_mint_transaction(
            &inputs,
            &decoys,
            mixin,
            xfg_burned,
            heat_minted,
            change,
            &keys.view_public,
            (&keys.spend_public, &keys.view_public),
            fee,
            &mut rand::thread_rng(),
        )
        .map_err(|e| format!("build: {e}"))?;

        let key_images = selected.iter().map(|u| u.key_image).collect();
        self.broadcast_built(built, key_images).await
    }

    /// Hearth AMM swap (XFG↔HEAT) against the pool at spot rate, 1% fee.
    /// direction: 0 = XFG→HEAT, 1 = HEAT→XFG. Validation/settlement follow
    /// the v11 delta model (Blockchain.cpp TX_EXTRA_AMM_SWAP_AUTH).
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
        let (_rx, _rh, spot_price) = self.daemon.amm_pool_info().await?;
        if spot_price == 0 {
            return Err("no pool price available".into());
        }

        let fee = MINIMUM_FEE;
        let mixin = DEFAULT_MIXIN;

        if direction == 0 {
            // XFG→HEAT: expected = gross * (1 - 1%) where
            // gross = input * spot / COIN.
            let gross = (input_amount as u128 * spot_price as u128 / COIN as u128) as u64;
            let expected_heat = (gross as u128 * 9900 / 10000) as u64;
            if expected_heat == 0 {
                return Err("swap output below 1 HEAT atomic".into());
            }
            if min_output > expected_heat {
                return Err(format!(
                    "min_output {} exceeds expected output {}",
                    min_output, expected_heat
                ));
            }

            let keys = self.wallet.lock().unwrap().wallet_keys();
            let selected = {
                let wallet = self.wallet.lock().unwrap();
                wallet
                    .select_for_send(input_amount + fee, &mut rand::thread_rng())
                    .map_err(|e| format!("coin selection: {e}"))?
            };

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
                if entries.len() < mixin {
                    return Err(format!(
                        "MIXIN_COUNT_TOO_BIG: only {} decoys available for amount {}",
                        entries.len(),
                        utxo.amount
                    ));
                }
                decoys.push(entries);
            }

            let inputs: Vec<fuego_sdk::transaction_builder::SpendableOutput> =
                selected.iter().map(|u| u.into()).collect();
            let built = fuego_sdk::transaction_builder::build_swap_xfg_to_heat_transaction(
                &inputs,
                &decoys,
                mixin,
                input_amount,
                expected_heat,
                min_output,
                (&keys.spend_public, &keys.view_public),
                &keys.view_public,
                fee,
                &mut rand::thread_rng(),
            )
            .map_err(|e| format!("build: {e}"))?;

            let key_images = selected.iter().map(|u| u.key_image).collect();
            return self.broadcast_built(built, key_images).await;
        }

        // HEAT→XFG: expected = gross * 99% where gross = input * COIN / spot.
        let gross = (input_amount as u128 * COIN as u128 / spot_price as u128) as u64;
        let expected_xfg = (gross as u128 * 9900 / 10000) as u64;
        if expected_xfg == 0 {
            return Err("swap output below 1 XFG atomic".into());
        }
        if min_output > expected_xfg {
            return Err(format!(
                "min_output {} exceeds expected output {}",
                min_output, expected_xfg
            ));
        }

        let keys = self.wallet.lock().unwrap().wallet_keys();
        let heat: Vec<fuego_sdk::scanner::CommitmentEntry> = self
            .wallet
            .lock()
            .unwrap()
            .heat_outputs()
            .into_iter()
            .filter(|d| d.global_index != 0)
            .collect();
        let needed = input_amount + MINIMUM_FEE;
        let mut selected = Vec::new();
        let mut found = 0u64;
        for entry in heat {
            found += entry.amount;
            selected.push(entry);
            if found >= needed {
                break;
            }
        }
        if found < needed {
            return Err(format!("insufficient HEAT: need {}, have {}", needed, found));
        }

        let heat_change = found - input_amount;
        let mut decoys = Vec::with_capacity(selected.len());
        for deposit in &selected {
            decoys.push(self.commitment_decoys(deposit, mixin).await?);
        }
        let spends: Vec<CommitmentDeposit> = selected
            .iter()
            .map(|d| CommitmentDeposit {
                amount: d.amount,
                commit_key: d.commit_key,
                key_scalar: d.key_scalar,
                key_image: d.key_image,
                global_index: d.global_index,
                claimed_interest: 0,
            })
            .collect();

        let built = fuego_sdk::transaction_builder::build_swap_heat_to_xfg_transaction(
            &spends,
            &decoys,
            mixin,
            input_amount,
            expected_xfg,
            min_output,
            (&keys.spend_public, &keys.view_public),
            heat_change,
            &keys.view_public,
            fee,
            &mut rand::thread_rng(),
        )
        .map_err(|e| format!("build: {e}"))?;

        let key_images: Vec<[u8; 32]> = selected.iter().map(|d| d.key_image).collect();
        self.broadcast_built(built, key_images).await
    }

    /// Hearth LP add: deposit XFG + HEAT at the pool ratio, mint LP shares
    /// (ammMintLpShares, AmmPool.cpp). Requires BOTH assets (no single-sided
    /// mints).
    pub async fn lp_add(
        &self,
        amount_xfg: u64,
        amount_heat: u64,
    ) -> std::result::Result<String, String> {
        if amount_xfg == 0 || amount_heat == 0 {
            return Err("both xfg_amount and heat_amount must be > 0".into());
        }
        let (reserve_xfg, reserve_heat, total_lp_shares, _spot) =
            self.daemon.amm_pool_full().await?;
        if total_lp_shares > 0 && (reserve_xfg == 0 || reserve_heat == 0) {
            return Err("pool has shares but empty reserves — invalid state".into());
        }

        let shares = if total_lp_shares == 0 {
            // First deposit: isqrt(amountXfg * amountHeat) - MIN_LIQUIDITY.
            let product = amount_xfg as u128 * amount_heat as u128;
            let root = isqrt128(product);
            root.saturating_sub(1000)
        } else {
            let sa = (amount_xfg as u128 * total_lp_shares as u128 / reserve_xfg as u128) as u64;
            let sb = (amount_heat as u128 * total_lp_shares as u128 / reserve_heat as u128) as u64;
            sa.min(sb)
        };
        if shares == 0 {
            return Err("computed LP shares are zero — amounts below pool ratio tick".into());
        }

        let fee = MINIMUM_FEE;
        let mixin = DEFAULT_MIXIN;
        let keys = self.wallet.lock().unwrap().wallet_keys();

        // XFG side: select key inputs for amount_xfg + fee.
        let selected_xfg = {
            let wallet = self.wallet.lock().unwrap();
            wallet
                .select_for_send(amount_xfg + fee, &mut rand::thread_rng())
                .map_err(|e| format!("coin selection: {e}"))?
        };
        let found_xfg: u64 = selected_xfg.iter().map(|u| u.amount).sum();
        let xfg_change = found_xfg - amount_xfg - fee;

        // HEAT side: select HEAT commitments for amount_heat.
        let heat: Vec<fuego_sdk::scanner::CommitmentEntry> = self
            .wallet
            .lock()
            .unwrap()
            .heat_outputs()
            .into_iter()
            .filter(|d| d.global_index != 0)
            .collect();
        let mut selected_heat = Vec::new();
        let mut found_heat = 0u64;
        for entry in heat {
            found_heat += entry.amount;
            selected_heat.push(entry);
            if found_heat >= amount_heat {
                break;
            }
        }
        if found_heat < amount_heat {
            return Err(format!("insufficient HEAT: need {}, have {}", amount_heat, found_heat));
        }
        let heat_change = found_heat - amount_heat;

        // Decoys for both input classes.
        let mut xfg_decoys: Vec<Vec<DecoyEntry>> = Vec::with_capacity(selected_xfg.len());
        let amounts: Vec<u64> = selected_xfg.iter().map(|u| u.amount).collect();
        let groups = self.daemon.get_random_outs(&amounts, (mixin + 1) as u64).await?;
        for utxo in selected_xfg.iter() {
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
            if entries.len() < mixin {
                return Err(format!(
                    "MIXIN_COUNT_TOO_BIG: only {} decoys available for amount {}",
                    entries.len(),
                    utxo.amount
                ));
            }
            xfg_decoys.push(entries);
        }
        let mut heat_decoys = Vec::with_capacity(selected_heat.len());
        for deposit in &selected_heat {
            heat_decoys.push(self.commitment_decoys(deposit, mixin).await?);
        }

        let xfg_inputs: Vec<fuego_sdk::transaction_builder::SpendableOutput> =
            selected_xfg.iter().map(|u| u.into()).collect();
        let heat_deposits: Vec<CommitmentDeposit> = selected_heat
            .iter()
            .map(|d| CommitmentDeposit {
                amount: d.amount,
                commit_key: d.commit_key,
                key_scalar: d.key_scalar,
                key_image: d.key_image,
                global_index: d.global_index,
                claimed_interest: 0,
            })
            .collect();

        let built = fuego_sdk::transaction_builder::build_lp_add_transaction(
            &xfg_inputs,
            &xfg_decoys,
            &heat_deposits,
            &heat_decoys,
            mixin,
            amount_xfg,
            amount_heat,
            shares,
            xfg_change,
            heat_change,
            &keys.view_public,
            (&keys.spend_public, &keys.view_public),
            fee,
            &mut rand::thread_rng(),
        )
        .map_err(|e| format!("build: {e}"))?;

        let mut key_images: Vec<[u8; 32]> = selected_xfg.iter().map(|u| u.key_image).collect();
        key_images.extend(selected_heat.iter().map(|d| d.key_image));
        self.broadcast_built(built, key_images).await
    }

    /// Hearth LP remove: burn LP shares, withdraw proportional reserves
    /// (ammGetWithdrawalAmounts, AmmPool.cpp).
    pub async fn lp_remove(
        &self,
        lp_shares: u64,
        min_xfg: u64,
        min_heat: u64,
    ) -> std::result::Result<String, String> {
        if lp_shares == 0 {
            return Err("shares must be > 0".into());
        }
        let (reserve_xfg, reserve_heat, total_lp_shares, _spot) =
            self.daemon.amm_pool_full().await?;
        if total_lp_shares == 0 {
            return Err("pool has no LP shares".into());
        }
        let amount_xfg = (lp_shares as u128 * reserve_xfg as u128 / total_lp_shares as u128) as u64;
        let amount_heat = (lp_shares as u128 * reserve_heat as u128 / total_lp_shares as u128) as u64;
        if amount_xfg < min_xfg || amount_heat < min_heat {
            return Err(format!(
                "withdrawal below minimum: {} XFG / {} HEAT",
                amount_xfg, amount_heat
            ));
        }

        let fee = MINIMUM_FEE;
        let mixin = DEFAULT_MIXIN;
        let keys = self.wallet.lock().unwrap().wallet_keys();

        let lp: Vec<fuego_sdk::scanner::CommitmentEntry> = self
            .wallet
            .lock()
            .unwrap()
            .deposits()
            .into_iter()
            .filter(|d| {
                d.term == fuego_sdk::serialization::DEPOSIT_TERM_LP && d.global_index != 0
            })
            .collect();
        let mut selected = Vec::new();
        let mut found = 0u64;
        for entry in lp {
            found += entry.amount;
            selected.push(entry);
            if found >= lp_shares {
                break;
            }
        }
        if found < lp_shares {
            return Err(format!("insufficient LP shares: need {}, have {}", lp_shares, found));
        }
        // Burn the exact share count: withdraw (lp_shares) of the selected
        // deposits; the remainder of the last deposit is returned as change
        // below via heat/xfg outputs only when it is a whole commitment —
        // LP change is not representable, so require exact coverage.
        let selected_total: u64 = selected.iter().map(|d| d.amount).sum();
        if selected_total != lp_shares {
            return Err(format!(
                "LP deposit selection {} does not exactly match shares {} (LP change unsupported)",
                selected_total, lp_shares
            ));
        }

        let mut decoys = Vec::with_capacity(selected.len());
        for deposit in &selected {
            decoys.push(self.commitment_decoys(deposit, mixin).await?);
        }
        let spends: Vec<CommitmentDeposit> = selected
            .iter()
            .map(|d| CommitmentDeposit {
                amount: d.amount,
                commit_key: d.commit_key,
                key_scalar: d.key_scalar,
                key_image: d.key_image,
                global_index: d.global_index,
                claimed_interest: 0,
            })
            .collect();

        let built = fuego_sdk::transaction_builder::build_lp_remove_transaction(
            &spends,
            &decoys,
            mixin,
            lp_shares,
            min_xfg,
            min_heat,
            amount_xfg,
            amount_heat,
            &keys.view_public,
            (&keys.spend_public, &keys.view_public),
            fee,
            &mut rand::thread_rng(),
        )
        .map_err(|e| format!("build: {e}"))?;

        let key_images: Vec<[u8; 32]> = selected.iter().map(|d| d.key_image).collect();
        self.broadcast_built(built, key_images).await
    }

    /// Hearth limit order (place_order): deposit XFG (SELL) or HEAT (BUY)
    /// into the pool commit key with a 0xFB limit-deposit extra.
    pub async fn place_limit_order(
        &self,
        side: u8,
        amount: u64,
        target_price: u64,
        expiration: u32,
    ) -> std::result::Result<String, String> {
        if amount == 0 {
            return Err("amount must be > 0".into());
        }
        if target_price == 0 {
            return Err("target_price must be > 0".into());
        }
        if side > 1 {
            return Err("side must be 0 (BUY) or 1 (SELL)".into());
        }

        let fee = MINIMUM_FEE;
        let mixin = DEFAULT_MIXIN;
        let keys = self.wallet.lock().unwrap().wallet_keys();

        let selected = {
            let wallet = self.wallet.lock().unwrap();
            wallet
                .select_for_send(amount + fee, &mut rand::thread_rng())
                .map_err(|e| format!("coin selection: {e}"))?
        };
        let found: u64 = selected.iter().map(|u| u.amount).sum();
        if found < amount + fee {
            return Err(format!("insufficient balance: need {}, have {}", amount + fee, found));
        }

        let mut order_id = [0u8; 32];
        rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut order_id);

        let mut key_data = [0u8; 64];
        key_data[..32].copy_from_slice(&keys.spend_public);
        key_data[32..].copy_from_slice(&keys.view_public);
        let address_hash = fuego_crypto::ring::cn_fast_hash(&key_data);

        let pool_seed = fuego_crypto::ring::cn_fast_hash(b"fuego.hearth.pool.commit.key.v1");
        let pool_scalar = fuego_crypto::ring::hash_to_scalar(&pool_seed);
        let pool_key = fuego_crypto::ring::secret_key_to_public_key(&pool_scalar);

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
            if entries.len() < mixin {
                return Err(format!(
                    "MIXIN_COUNT_TOO_BIG: only {} decoys available for amount {}",
                    entries.len(),
                    utxo.amount
                ));
            }
            decoys.push(entries);
        }

        let inputs: Vec<fuego_sdk::transaction_builder::SpendableOutput> =
            selected.iter().map(|u| u.into()).collect();
        let built = fuego_sdk::transaction_builder::build_place_order_transaction(
            &inputs,
            &decoys,
            mixin,
            side,
            amount,
            target_price,
            expiration,
            &order_id,
            &address_hash,
            &pool_key,
            (&keys.spend_public, &keys.view_public),
            &keys.view_public,
            fee,
            &mut rand::thread_rng(),
        )
        .map_err(|e| format!("build: {e}"))?;

        let key_images = selected.iter().map(|u| u.key_image).collect();
        self.broadcast_built(built, key_images).await
    }

    /// create_cd / heat_cd: lock HEAT into a finite-term CD. The only CD
    /// type on the chain is HEAT-denominated (DEPOSIT_ARCHITECTURE.md: the
    /// legacy COLD/XFG system was removed); spending HEAT deposits builds a
    /// CD commitment output with a finite block term plus a banking fee
    /// burned to the treasury via the 0xFF extra.
    async fn heat_cd_core(
        &self,
        amount: u64,
        term_blocks: u32,
        banking_fee: u64,
    ) -> std::result::Result<String, String> {
        if amount == 0 {
            return Err("amount must be > 0".into());
        }
        if term_blocks == 0 {
            return Err("term must be > 0 blocks".into());
        }
        let banking_fee = if banking_fee == 0 {
            (amount / 1000).max(1)
        } else {
            banking_fee
        };

        let heat: Vec<fuego_sdk::scanner::CommitmentEntry> = self
            .wallet
            .lock()
            .unwrap()
            .heat_outputs()
            .into_iter()
            .filter(|d| d.global_index != 0)
            .collect();
        // The fee is the difference between inputs and outputs, so the
        // selection must cover amount + banking_fee + fee.
        let needed = amount + banking_fee + MINIMUM_FEE;
        let mut selected = Vec::new();
        let mut found = 0u64;
        for entry in heat {
            found += entry.amount;
            selected.push(entry);
            if found >= needed {
                break;
            }
        }
        if found < needed {
            return Err(format!(
                "insufficient HEAT: need {}, have {}",
                needed, found
            ));
        }

        let fee = MINIMUM_FEE;
        let mixin = DEFAULT_MIXIN;
        let mut decoys = Vec::with_capacity(selected.len());
        for deposit in &selected {
            decoys.push(self.commitment_decoys(deposit, mixin).await?);
        }

        let keys = self.wallet.lock().unwrap().wallet_keys();
        let heat_change = found - amount - banking_fee - fee;

        let mut commitment_dests = vec![BuildCommitmentDestination {
            amount,
            term: term_blocks,
            view_pub: None,
        }];
        if heat_change > 0 {
            commitment_dests.push(BuildCommitmentDestination {
                amount: heat_change,
                term: HEAT_TERM,
                view_pub: None,
            });
        }

        let mut extra_extra = Vec::new();
        add_treasury_fund_extra(&mut extra_extra, 1 /* HEAT */, banking_fee);

        let spends: Vec<CommitmentDeposit> = selected
            .iter()
            .map(|d| CommitmentDeposit {
                amount: d.amount,
                commit_key: d.commit_key,
                key_scalar: d.key_scalar,
                key_image: d.key_image,
                global_index: d.global_index,
                claimed_interest: 0,
            })
            .collect();
        let built = build_commitment_spend_transaction(
            &spends,
            &decoys,
            mixin,
            &[],
            &commitment_dests,
            &keys.view_public,
            fee,
            &extra_extra,
            &mut rand::thread_rng(),
        )
        .map_err(|e| format!("build: {e}"))?;

        let key_images: Vec<[u8; 32]> = selected.iter().map(|d| d.key_image).collect();
        self.broadcast_built(built, key_images).await
    }

    /// create_cd: HEAT CD with an explicit block term (the GUI passes
    /// duration_blocks directly).
    pub async fn create_cd(
        &self,
        amount: u64,
        term_blocks: u32,
    ) -> std::result::Result<String, String> {
        if term_blocks < DEPOSIT_MIN_TERM || term_blocks > DEPOSIT_MAX_TERM {
            return Err(format!(
                "term must be in {}..={} blocks",
                DEPOSIT_MIN_TERM, DEPOSIT_MAX_TERM
            ));
        }
        self.heat_cd_core(amount, term_blocks, 0).await
    }

    /// heat_cd: HEAT CD with the term expressed in epochs (CLI-style).
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
        let term_blocks = (epochs as u64 * epoch_blocks) as u32;
        if term_blocks < DEPOSIT_MIN_TERM || term_blocks > DEPOSIT_MAX_TERM {
            return Err(format!(
                "term must be in {}..={} blocks",
                DEPOSIT_MIN_TERM, DEPOSIT_MAX_TERM
            ));
        }
        self.heat_cd_core(amount, term_blocks, banking_fee).await
    }

    /// claim_cd: spend all mature finite-term deposits back to ourselves.
    pub async fn claim_cd(&self) -> std::result::Result<String, String> {
        let height = self.wallet.lock().unwrap().height();
        let deposits: Vec<fuego_sdk::scanner::CommitmentEntry> = self
            .wallet
            .lock()
            .unwrap()
            .deposits()
            .into_iter()
            .filter(|d| d.block_height + d.term as u64 <= height && d.global_index != 0)
            .collect();
        if deposits.is_empty() {
            return Err("no mature deposits to claim".into());
        }

        let fee = MINIMUM_FEE;

        // Interest per deposit via /estimate_cd_yield (the daemon's
        // calculateCdInterest). Fall back to 0 if the endpoint is
        // unavailable; the daemon caps per-tx claims against the fee pool.
        let mut interests = Vec::with_capacity(deposits.len());
        for deposit in &deposits {
            let interest = self
                .daemon
                .estimate_cd_yield(deposit.amount, deposit.block_height as u32)
                .await
                .unwrap_or(0);
            interests.push(interest);
        }

        let total: u64 = deposits
            .iter()
            .zip(interests.iter())
            .map(|(d, i)| d.amount + i)
            .sum();
        if total <= fee {
            return Err("deposit total below fee".into());
        }
        let payout = total - fee;

        let mixin = DEFAULT_MIXIN;
        let mut decoys = Vec::with_capacity(deposits.len());
        for deposit in &deposits {
            decoys.push(self.commitment_decoys(deposit, mixin).await?);
        }

        let keys = self.wallet.lock().unwrap().wallet_keys();
        let (chunks, dust) = decompose_change(payout, DEFAULT_DUST_THRESHOLD);
        let mut key_dests: Vec<BuildDestination> = Vec::with_capacity(chunks.len() + 1);
        for chunk in chunks {
            key_dests.push(BuildDestination {
                amount: chunk,
                spend_pub: keys.spend_public,
                view_pub: keys.view_public,
            });
        }
        if dust > 0 {
            key_dests.push(BuildDestination {
                amount: dust,
                spend_pub: keys.spend_public,
                view_pub: keys.view_public,
            });
        }

        let spends: Vec<CommitmentDeposit> = deposits
            .iter()
            .zip(interests.iter())
            .map(|(d, interest)| CommitmentDeposit {
                amount: d.amount,
                commit_key: d.commit_key,
                key_scalar: d.key_scalar,
                key_image: d.key_image,
                global_index: d.global_index,
                claimed_interest: *interest,
            })
            .collect();
        let built = build_commitment_spend_transaction(
            &spends,
            &decoys,
            mixin,
            &key_dests,
            &[],
            &keys.view_public,
            fee,
            &[],
            &mut rand::thread_rng(),
        )
        .map_err(|e| format!("build: {e}"))?;

        let key_images: Vec<[u8; 32]> = deposits.iter().map(|d| d.key_image).collect();
        self.broadcast_built(built, key_images).await
    }

    /// send_heat: transfer HEAT to another address. The recipient's
    /// commitment output derives with THEIR view key; our HEAT change with
    /// ours. Carries the 0xF9 heat-send auth extra.
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

        let heat: Vec<fuego_sdk::scanner::CommitmentEntry> = self
            .wallet
            .lock()
            .unwrap()
            .heat_outputs()
            .into_iter()
            .filter(|d| d.global_index != 0)
            .collect();
        let needed = amount + MINIMUM_FEE;
        let mut selected = Vec::new();
        let mut found = 0u64;
        for entry in heat {
            found += entry.amount;
            selected.push(entry);
            if found >= needed {
                break;
            }
        }
        if found < needed {
            return Err(format!(
                "insufficient HEAT: need {}, have {}",
                needed, found
            ));
        }
        let change = found - amount - MINIMUM_FEE;

        let mixin = DEFAULT_MIXIN;
        let mut decoys = Vec::with_capacity(selected.len());
        for deposit in &selected {
            decoys.push(self.commitment_decoys(deposit, mixin).await?);
        }

        let keys = self.wallet.lock().unwrap().wallet_keys();
        let mut commitment_dests = vec![BuildCommitmentDestination {
            amount,
            term: HEAT_TERM,
            view_pub: Some(recv_view),
        }];
        if change > 0 {
            commitment_dests.push(BuildCommitmentDestination {
                amount: change,
                term: HEAT_TERM,
                view_pub: None,
            });
        }

        let mut extra = Vec::new();
        fuego_sdk::serialization::add_heat_send_auth_extra(&mut extra, amount);

        let spends: Vec<CommitmentDeposit> = selected
            .iter()
            .map(|d| CommitmentDeposit {
                amount: d.amount,
                commit_key: d.commit_key,
                key_scalar: d.key_scalar,
                key_image: d.key_image,
                global_index: d.global_index,
                claimed_interest: 0,
            })
            .collect();
        let built = build_commitment_spend_transaction(
            &spends,
            &decoys,
            mixin,
            &[],
            &commitment_dests,
            &keys.view_public,
            MINIMUM_FEE,
            &extra,
            &mut rand::thread_rng(),
        )
        .map_err(|e| format!("build: {e}"))?;

        let _ = &recv_spend;
        let key_images: Vec<[u8; 32]> = selected.iter().map(|d| d.key_image).collect();
        self.broadcast_built(built, key_images).await
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

    pub async fn list_cds(&self) -> Vec<String> {
        self.wallet
            .lock()
            .unwrap()
            .deposits()
            .iter()
            .map(|d| format!("{}:{}:{}", hex::encode(d.tx_hash), d.amount, d.term))
            .collect()
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
