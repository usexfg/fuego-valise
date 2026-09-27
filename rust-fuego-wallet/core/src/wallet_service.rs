use crate::daemon::DaemonClient;

use fuego_sdk::scanner::{BalanceBreakdown, CommitmentEntry, HistoryEntry, UtxoEntry};
use fuego_sdk::serialization::{
    add_cd_bonus_claim_extra, add_payment_id_nonce, add_treasury_fund_extra, DEPOSIT_TERM_LP,
    HEAT_TERM,
};
use fuego_sdk::suite;
use fuego_sdk::transaction_builder::{
    build_commitment_spend_transaction, decompose_change, BuildCommitmentDestination,
    BuildDestination, CommitmentDeposit, DecoyEntry, DEFAULT_DUST_THRESHOLD, MINIMUM_FEE,
};
use fuego_sdk::*;
use rand::seq::SliceRandom;
use rand::Rng;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

const COIN: u64 = suite::COIN;
/// Dynamax approved ring sizes (DynamicRingSize.cpp getTargetRingSizes).
const DYNAMAX_RING_SIZES: [usize; 3] = [32, 16, 8];
/// Most finite CDs spent by one claim transaction.
const MAX_CLAIM_INPUTS: usize = 64;
/// Persisted scanner-state layout. A mismatch clears scanner state and
/// rescans from genesis (pending sends and stored tx blobs are kept).
const STATE_VERSION: u32 = 2;

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

/// Dynamax: largest of {32,16,8} ring members achievable from `available`
/// same-amount outputs (real included). Testnet may bootstrap below 8;
/// mainnet consensus rejects rings under MIN_TX_MIXIN_SIZE_V10 (Core.cpp
/// check_tx_mixin), so there is no mainnet fallback.
fn dynamax_ring_size(available: usize, testnet: bool) -> Option<usize> {
    let max_ring = suite::MAX_TX_MIXIN_SIZE as usize;
    DYNAMAX_RING_SIZES
        .iter()
        .copied()
        .find(|&r| r <= max_ring && r <= available)
        .or_else(|| (testnet && available > 0).then(|| available.min(max_ring)))
}

fn commitment_deposit(d: &CommitmentEntry, claimed_interest: u64) -> CommitmentDeposit {
    CommitmentDeposit {
        amount: d.amount,
        commit_key: d.commit_key,
        key_scalar: d.key_scalar,
        key_image: d.key_image,
        global_index: d.global_index,
        claimed_interest,
    }
}

fn parse_payment_id(hex_id: &str) -> std::result::Result<[u8; 32], String> {
    let mut id = [0u8; 32];
    hex::decode_to_slice(hex_id.trim(), &mut id)
        .map_err(|_| "payment id must be 64 hex characters".to_string())?;
    Ok(id)
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
            hex::encode(sha2::Sha256::digest(secret))
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

/// A finite-term CD owned by this wallet. `cd_id` = "<tx hash>:<output index>".
#[derive(Debug, Clone)]
pub struct CdView {
    pub cd_id: String,
    pub amount: u64,
    pub term: u32,
    pub deposit_height: u64,
    pub maturity_height: u64,
    pub matured: bool,
}

/// Result of a CD claim transaction.
#[derive(Debug, Clone)]
pub struct CdClaim {
    pub tx_hash: String,
    pub cd_ids: Vec<String>,
    pub principal: u64,
    pub interest: u64,
}

fn cd_id(d: &CommitmentEntry) -> String {
    format!("{}:{}", hex::encode(d.tx_hash), d.output_position)
}

/// Optional sendTransaction fields (walletd SendTransaction::Request).
#[derive(Debug, Default, Clone)]
pub struct SendOptions {
    pub payment_id: Option<String>,
    pub extra_hex: Option<String>,
    pub unlock_time: u64,
}

pub struct WalletService {
    pub wallet: Arc<Mutex<Wallet>>,
    pub daemon: DaemonClient,
    db: sled::Db,
    testnet: bool,
    known_height: Arc<AtomicU64>,
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
    known_height: Arc<AtomicU64>,
}

const KEY_HEIGHT: &[u8] = b"height";
const KEY_TOP_HASH: &[u8] = b"top_hash";
const KEY_STATE_VERSION: &[u8] = b"state_version";
const SCANNER_KEYS: [&[u8]; 6] = [b"utxos", b"commitments", b"spent", b"history", KEY_HEIGHT, KEY_TOP_HASH];

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
            known_height: Arc::new(AtomicU64::new(0)),
            afk_secrets: Arc::new(Mutex::new(HashMap::new())),
        };
        service.sync_engine().load_state();
        Ok(service)
    }

    fn address_prefix(&self) -> u64 {
        if self.testnet {
            suite::CRYPTONOTE_PUBLIC_ADDRESS_BASE58_PREFIX_TESTNET
        } else {
            suite::CRYPTONOTE_PUBLIC_ADDRESS_BASE58_PREFIX
        }
    }

    /// The wallet's primary address for the configured network.
    pub fn primary_address_string(&self) -> String {
        let keys = self.wallet.lock().unwrap().wallet_keys();
        fuego_crypto::make_address_with_prefix(&keys.spend_public, &keys.view_public, self.address_prefix()).0
    }

    /// One incremental sync round over /queryblockslite.bin.
    pub async fn sync_once(&self) -> std::result::Result<u64, String> {
        self.sync_engine().sync_once().await
    }
}

impl SyncEngine {
    fn load_state(&self) {
        let db = &self.db;
        let version = db
            .get(KEY_STATE_VERSION)
            .ok()
            .flatten()
            .and_then(|b| bincode::deserialize::<u32>(&b).ok())
            .unwrap_or(0);
        if version != STATE_VERSION {
            log::info!(
                "wallet state layout {} -> {}: clearing scanner state, rescanning from genesis",
                version,
                STATE_VERSION
            );
            for key in SCANNER_KEYS {
                let _ = db.remove(key);
            }
            let _ = bincode::serialize(&STATE_VERSION).ok().and_then(|b| db.insert(KEY_STATE_VERSION, b).ok());
            let _ = db.flush();
        }

        let wallet = self.wallet.lock().unwrap();
        if let Ok(Some(bytes)) = db.get(b"utxos") {
            if let Ok(utxos) = bincode::deserialize::<Vec<UtxoEntry>>(&bytes) {
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
                        .and_then(|b| bincode::deserialize::<Vec<CommitmentEntry>>(&b).ok())
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
                        .and_then(|b| bincode::deserialize::<Vec<HistoryEntry>>(&b).ok())
                        .unwrap_or_default(),
                };
                wallet.restore_state(&snapshot);
            }
        }

        // Re-reserve pending sends (persist-before-broadcast: never release
        // these automatically).
        if let Ok(Some(bytes)) = db.get(b"pending") {
            if let Ok(pending) = bincode::deserialize::<Vec<PendingTx>>(&bytes) {
                let images: Vec<[u8; 32]> = pending.iter().flat_map(|p| p.key_images.clone()).collect();
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
        let _ = bincode::serialize(&STATE_VERSION).ok().and_then(|b| db.insert(KEY_STATE_VERSION, b).ok());
        let _ = db.flush();
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
        let info = self.daemon.get_info().await?;
        self.known_height.store(info.height, Ordering::Relaxed);
        let our_height = self.wallet.lock().unwrap().height();

        if info.height <= our_height {
            return Ok(0);
        }

        // The daemon rejects locators whose LAST id is not the genesis hash
        // (Core.cpp findStartAndFullOffsets). Locator order is newest first,
        // genesis always last.
        let genesis_hex = self.daemon.get_block_hash(0).await?;
        let mut genesis = [0u8; 32];
        hex::decode_to_slice(genesis_hex.trim(), &mut genesis).map_err(|e| format!("genesis hash: {e}"))?;

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
            let timestamp = fuego_sdk::serialization::parse_block_timestamp(&item.block).unwrap_or(0);

            for txi in &item.tx_prefixes {
                let received = {
                    let wallet = self.wallet.lock().unwrap();
                    wallet
                        .scan_tx_prefix_at(&txi.tx_hash, &txi.parsed, block_height, timestamp)
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

            self.wallet.lock().unwrap().set_height(block_height);
            self.set_top_hash(&item.block_id);
            scanned += 1;
        }

        if scanned > 0 {
            // Reconcile unspent outputs against the daemon's key image index
            // (covers outputs spent before a seed restore).
            self.reconcile_spent().await;
            self.persist_state();
        }

        Ok(scanned)
    }

    /// Background sync loop; never returns.
    pub async fn sync_loop(&self) {
        loop {
            match self.sync_once().await {
                Ok(0) => tokio::time::sleep(std::time::Duration::from_secs(30)).await,
                Ok(n) => log::info!("Synced {} blocks", n),
                Err(e) => {
                    log::error!("Sync error: {}", e);
                    tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                }
            }
        }
    }

    /// Remove pending entries whose transaction is now in a scanned block.
    fn confirm_pending(&self, prefixes: &[fuego_sdk::serialization::TxPrefixInfo]) {
        let mut pending = self.pending();
        if pending.is_empty() {
            return;
        }
        let before = pending.len();
        pending.retain(|p| !prefixes.iter().any(|x| x.tx_hash == p.tx_hash));
        if pending.len() != before {
            self.store_pending(&pending);
        }
    }

    /// Ask the daemon (/is_key_image_spent) whether any unspent output's key
    /// image is spent; stops at the first transport error and relies on scans.
    async fn reconcile_spent(&self) {
        let utxos = self.wallet.lock().unwrap().utxos();
        for utxo in utxos {
            match self.daemon.is_key_image_spent(&utxo.key_image).await {
                Ok(true) => {
                    log::info!(
                        "key image {} marked spent by daemon (tx {})",
                        hex::encode(utxo.key_image),
                        hex::encode(utxo.tx_hash)
                    );
                    self.wallet.lock().unwrap().reserve_pending(&[utxo.key_image]);
                }
                Ok(false) => {}
                Err(e) => {
                    log::warn!("is_key_image_spent unavailable: {}", e);
                    return;
                }
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
            known_height: self.known_height.clone(),
        }
    }

    // ------------------------------------------------------------ ring policy

    /// Decoys per key input, mirroring walletd (PaymentGate WalletService):
    /// mainnet mixIn = max(anonymity, MIN_TX_MIXIN_SIZE_V10), testnet 0.
    fn key_mixin(&self, anonymity: u32) -> usize {
        if self.testnet {
            return 0;
        }
        (anonymity as u64)
            .max(suite::MIN_TX_MIXIN_SIZE_V10)
            .min(suite::MAX_TX_MIXIN_SIZE) as usize
    }

    /// Exactly `mixin` random decoys per selected key input.
    async fn key_decoys(
        &self,
        selected: &[UtxoEntry],
        mixin: usize,
    ) -> std::result::Result<Vec<Vec<DecoyEntry>>, String> {
        if mixin == 0 {
            return Ok(vec![Vec::new(); selected.len()]);
        }
        let amounts: Vec<u64> = selected.iter().map(|u| u.amount).collect();
        let groups = self.daemon.get_random_outs(&amounts, (mixin + 1) as u64).await?;
        let mut rng = rand::thread_rng();
        selected
            .iter()
            .map(|utxo| {
                let group = groups
                    .iter()
                    .find(|g| g.amount == utxo.amount)
                    .ok_or_else(|| format!("daemon returned no decoys for amount {}", utxo.amount))?;
                let mut entries: Vec<DecoyEntry> = group
                    .outs
                    .iter()
                    .filter(|o| o.global_amount_index != utxo.global_index as u64)
                    .map(|o| DecoyEntry { global_index: o.global_amount_index as u32, out_key: o.out_key })
                    .collect();
                entries.sort_by_key(|e| e.global_index);
                entries.dedup_by_key(|e| e.global_index);
                entries.shuffle(&mut rng);
                entries.truncate(mixin);
                if entries.len() < mixin {
                    return Err(format!(
                        "MIXIN_COUNT_TOO_BIG: only {} decoys available for amount {} (need {})",
                        entries.len(),
                        utxo.amount,
                        mixin
                    ));
                }
                Ok(entries)
            })
            .collect()
    }

    /// Commitment ring decoys (WalletGreen Dynamax): probe MAX_TX_MIXIN_SIZE
    /// outputs created at or below the real output's height, then settle on
    /// the largest approved ring the pool supports.
    async fn commitment_decoys(
        &self,
        entry: &CommitmentEntry,
    ) -> std::result::Result<Vec<(u32, [u8; 32])>, String> {
        let outs = match self
            .daemon
            .get_random_commitment_outs(entry.amount, suite::MAX_TX_MIXIN_SIZE, entry.block_height as u32)
            .await
        {
            Ok(outs) => outs,
            Err(_) if self.testnet => Vec::new(),
            Err(e) => return Err(e),
        };
        let mut decoys: Vec<(u32, [u8; 32])> = outs
            .into_iter()
            .filter(|e| e.global_amount_index != entry.global_index)
            .map(|e| (e.global_amount_index, e.commit_key))
            .collect();
        decoys.sort_by_key(|d| d.0);
        decoys.dedup_by_key(|d| d.0);
        let ring = dynamax_ring_size(decoys.len() + 1, self.testnet).ok_or_else(|| {
            format!(
                "MIXIN_COUNT_TOO_BIG: only {} commitment decoys for amount {} (mainnet ring minimum {})",
                decoys.len(),
                entry.amount,
                suite::MIN_TX_MIXIN_SIZE_V10
            )
        })?;
        decoys.shuffle(&mut rand::thread_rng());
        decoys.truncate(ring - 1);
        Ok(decoys)
    }

    /// Spendable HEAT covering `needed`, oldest-first order as scanned.
    fn select_heat(&self, needed: u64) -> std::result::Result<(Vec<CommitmentEntry>, u64), String> {
        let heat = self.wallet.lock().unwrap().spendable_heat_outputs();
        let mut selected = Vec::new();
        let mut found = 0u64;
        for entry in heat {
            if found >= needed {
                break;
            }
            found += entry.amount;
            selected.push(entry);
        }
        if found < needed {
            return Err(format!("insufficient spendable HEAT: need {}, have {}", needed, found));
        }
        Ok((selected, found))
    }

    fn select_xfg(&self, total: u64) -> std::result::Result<Vec<UtxoEntry>, String> {
        self.wallet
            .lock()
            .unwrap()
            .select_for_send(total, &mut rand::thread_rng())
            .map_err(|e| format!("coin selection: {e}"))
    }

    fn deposit_term_bounds(&self) -> (u32, u32) {
        if self.testnet {
            (suite::TESTNET_DEPOSIT_MIN_TERM, suite::TESTNET_DEPOSIT_MAX_TERM)
        } else {
            (suite::DEPOSIT_MIN_TERM, suite::DEPOSIT_MAX_TERM)
        }
    }

    fn upgrade_height_v11(&self) -> u64 {
        if self.testnet {
            suite::TESTNET_UPGRADE_HEIGHT_V11 as u64
        } else {
            suite::UPGRADE_HEIGHT_V11 as u64
        }
    }

    // ------------------------------------------------------------ send

    /// walletd sendTransaction: XFG to one or more addresses (integrated
    /// addresses carry their payment id), optional paymentId / raw extra
    /// (mutually exclusive, as in SendTransaction::Request) and unlockTime.
    pub async fn send_transaction(
        &self,
        destinations: &[(String, u64)],
        fee: u64,
        anonymity: u32,
        opts: SendOptions,
    ) -> std::result::Result<String, String> {
        if destinations.is_empty() {
            return Err("no transfers".into());
        }
        if opts.payment_id.is_some() && opts.extra_hex.is_some() {
            return Err("paymentId and extra are mutually exclusive".into());
        }
        let mut payment_id = opts.payment_id.as_deref().map(parse_payment_id).transpose()?;
        for (addr, amount) in destinations {
            if *amount == 0 {
                return Err(format!("zero amount to {addr}"));
            }
            let parsed = fuego_crypto::parse_address_full(addr)
                .ok_or_else(|| format!("invalid destination address: {addr}"))?;
            if parsed.prefix != self.address_prefix() {
                return Err(format!("address {addr} belongs to another network"));
            }
            if let Some(embedded) = parsed.payment_id {
                match payment_id {
                    Some(p) if p != embedded => {
                        return Err("integrated address payment id conflicts with paymentId".into())
                    }
                    _ => payment_id = Some(embedded),
                }
            }
        }
        let mut extra = Vec::new();
        if let Some(pid) = payment_id {
            add_payment_id_nonce(&mut extra, &pid);
        }
        if let Some(raw) = opts.extra_hex {
            extra.extend(hex::decode(raw.trim()).map_err(|_| "extra must be hex".to_string())?);
        }
        self.send_keys(destinations, fee, self.key_mixin(anonymity), &extra, opts.unlock_time)
            .await
    }

    /// Build, persist and broadcast a KeyInput transaction.
    async fn send_keys(
        &self,
        destinations: &[(String, u64)],
        fee: u64,
        mixin: usize,
        extra: &[u8],
        unlock_time: u64,
    ) -> std::result::Result<String, String> {
        let fee = fee.max(MINIMUM_FEE);
        let total: u64 = destinations.iter().map(|(_, a)| *a).sum::<u64>() + fee;
        let selected = self.select_xfg(total)?;
        let decoys = self.key_decoys(&selected, mixin).await?;
        let dests: Vec<(Address, u64)> =
            destinations.iter().map(|(addr, amount)| (Address(addr.clone()), *amount)).collect();
        let built = {
            let wallet = self.wallet.lock().unwrap();
            wallet
                .build_with_selection_ext(
                    &selected,
                    &dests,
                    fee,
                    mixin,
                    &decoys,
                    unlock_time,
                    extra,
                    &mut rand::thread_rng(),
                )
                .map_err(|e| format!("build: {e}"))?
        };
        let key_images: Vec<[u8; 32]> = selected.iter().map(|u| u.key_image).collect();
        self.broadcast_built(built, key_images).await
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
        let _ = self.db.insert(format!("txs:{}", tx_hash_hex).as_bytes(), serialized_hex.as_bytes());

        let engine = self.sync_engine();
        let mut pending = engine.pending();
        pending.push(PendingTx {
            tx_hash: built.tx_hash,
            key_images: key_images.clone(),
            serialized_hex: serialized_hex.clone(),
            created_height: self.wallet.lock().unwrap().height(),
        });
        engine.store_pending(&pending);
        self.wallet.lock().unwrap().reserve_pending(&key_images);

        let status = self.daemon.send_raw_tx(&serialized_hex).await?;
        match status.as_str() {
            "OK" => log::info!("Transaction {} submitted", tx_hash_hex),
            "Failed" => {
                let mut pending = engine.pending();
                pending.retain(|p| p.tx_hash != built.tx_hash);
                engine.store_pending(&pending);
                return Err(format!("daemon rejected transaction: {}", status));
            }
            other => log::warn!("Transaction {} relay status: {} (inputs stay reserved)", tx_hash_hex, other),
        }
        Ok(tx_hash_hex)
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
        let fee_bob = amount * suite::SWAP_FEE_RATE_BPS / suite::SWAP_FEE_RATE_DIVISOR;
        let total = amount + fee_bob;
        let unlock_time = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_secs()
            + (timeout_hours as u64) * 3600;

        let own_address = self.primary_address_string();
        let mixin = self.key_mixin(0);
        let selected = self.select_xfg(total + MINIMUM_FEE)?;
        let decoys = self.key_decoys(&selected, mixin).await?;
        let built = {
            let wallet = self.wallet.lock().unwrap();
            wallet
                .build_with_selection_ext(
                    &selected,
                    &[(Address(own_address.clone()), total)],
                    MINIMUM_FEE,
                    mixin,
                    &decoys,
                    unlock_time,
                    &[],
                    &mut rand::thread_rng(),
                )
                .map_err(|e| format!("build: {e}"))?
        };

        let keys = self.wallet.lock().unwrap().wallet_keys();
        let (secret, adaptor_point, pre_sig) = fuego_crypto::ring::generate_afk_lock_data(
            &[0u8; 32],
            &keys.spend_public,
            &keys.spend_secret,
            &mut rand::thread_rng(),
        )
        .ok_or("adaptor pre-signature generation failed")?;

        // hashLock = H(t): claim() reveals the adaptor secret t as the HTLC
        // preimage, so the hashlock committed here MUST be H(t) — never the
        // adaptor point T = t*G (SwapHashLock.h).
        let hash_lock = afk_hash_lock(pair, &secret);

        let key_images: Vec<[u8; 32]> = selected.iter().map(|u| u.key_image).collect();
        let lock_id = hex::encode(built.tx_hash);
        self.broadcast_built(built, key_images).await?;

        // Keep the AFK secret in memory only (like WalletLegacy
        // m_afkLockSecrets). Persisting t plaintext would let any local
        // reader of wallet_state.sled complete the adaptor signature.
        self.afk_secrets.lock().unwrap().insert(
            lock_id.clone(),
            AfkLockSecret { secret, pre_sig: pre_sig.to_vec(), amount, timeout_hours, pair },
        );

        Ok((lock_id, hex::encode(adaptor_point), hex::encode(pre_sig), hash_lock))
    }

    /// mint_heat: burn XFG, mint HEAT at the price consensus validates
    /// against — the 8-block rolling TWAP (Blockchain.cpp, v11+), falling
    /// back to spot only when no TWAP exists yet.
    /// Returns (tx hash, HEAT minted, price used).
    pub async fn mint_heat(&self, xfg_burned: u64) -> std::result::Result<(String, u64, u64), String> {
        if xfg_burned == 0 {
            return Err("xfg_burned must be > 0".into());
        }
        let pool = self.daemon.amm_pool_info().await?;
        let price = if pool.hearth_twap > 0 { pool.hearth_twap } else { pool.spot_price };
        if price == 0 {
            return Err("no pool price available".into());
        }
        let heat_minted = (xfg_burned as u128 * price as u128 / COIN as u128) as u64;
        if heat_minted < suite::HEAT_MINT_MIN_HEAT {
            return Err(format!("minted HEAT {} below minimum {}", heat_minted, suite::HEAT_MINT_MIN_HEAT));
        }

        let fee = MINIMUM_FEE;
        let keys = self.wallet.lock().unwrap().wallet_keys();
        let selected = self.select_xfg(xfg_burned + fee)?;
        let change = selected.iter().map(|u| u.amount).sum::<u64>() - xfg_burned - fee;
        let mixin = self.key_mixin(0);
        let decoys = self.key_decoys(&selected, mixin).await?;

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
        let tx_hash = self.broadcast_built(built, key_images).await?;
        Ok((tx_hash, heat_minted, price))
    }

    /// Hearth AMM swap (XFG↔HEAT) at the pool spot rate, 1% taker fee
    /// (Blockchain.cpp v11 TX_EXTRA_AMM_SWAP_AUTH validation).
    /// direction: 0 = XFG→HEAT, 1 = HEAT→XFG.
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
        let spot_price = self.daemon.amm_pool_info().await?.spot_price;
        if spot_price == 0 {
            return Err("no pool price available".into());
        }
        let fee = MINIMUM_FEE;
        let keep = suite::HEARTH_FEE_DIVISOR - suite::HEARTH_FEE_BPS;
        let keys = self.wallet.lock().unwrap().wallet_keys();

        if direction == 0 {
            let gross = (input_amount as u128 * spot_price as u128 / COIN as u128) as u64;
            let expected_heat = (gross as u128 * keep as u128 / suite::HEARTH_FEE_DIVISOR as u128) as u64;
            if expected_heat == 0 {
                return Err("swap output below 1 HEAT atomic".into());
            }
            if min_output > expected_heat {
                return Err(format!("min_output {} exceeds expected output {}", min_output, expected_heat));
            }
            let mixin = self.key_mixin(0);
            let selected = self.select_xfg(input_amount + fee)?;
            let decoys = self.key_decoys(&selected, mixin).await?;
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

        let gross = (input_amount as u128 * COIN as u128 / spot_price as u128) as u64;
        let expected_xfg = (gross as u128 * keep as u128 / suite::HEARTH_FEE_DIVISOR as u128) as u64;
        if expected_xfg == 0 {
            return Err("swap output below 1 XFG atomic".into());
        }
        if min_output > expected_xfg {
            return Err(format!("min_output {} exceeds expected output {}", min_output, expected_xfg));
        }
        let (selected, found) = self.select_heat(input_amount + fee)?;
        let mut decoys = Vec::with_capacity(selected.len());
        for entry in &selected {
            decoys.push(self.commitment_decoys(entry).await?);
        }
        let spends: Vec<CommitmentDeposit> = selected.iter().map(|d| commitment_deposit(d, 0)).collect();
        let built = fuego_sdk::transaction_builder::build_swap_heat_to_xfg_transaction(
            &spends,
            &decoys,
            DYNAMAX_RING_SIZES[2],
            input_amount,
            expected_xfg,
            min_output,
            (&keys.spend_public, &keys.view_public),
            found - input_amount,
            &keys.view_public,
            fee,
            &mut rand::thread_rng(),
        )
        .map_err(|e| format!("build: {e}"))?;
        let key_images: Vec<[u8; 32]> = selected.iter().map(|d| d.key_image).collect();
        self.broadcast_built(built, key_images).await
    }

    /// Hearth LP add: deposit XFG + HEAT at the pool ratio, mint LP shares
    /// (ammMintLpShares, AmmPool.cpp). Requires BOTH assets.
    pub async fn lp_add(&self, amount_xfg: u64, amount_heat: u64) -> std::result::Result<String, String> {
        if amount_xfg == 0 || amount_heat == 0 {
            return Err("both xfg_amount and heat_amount must be > 0".into());
        }
        let pool = self.daemon.amm_pool_info().await?;
        let (reserve_xfg, reserve_heat, total_lp_shares) = (pool.reserve_xfg, pool.reserve_heat, pool.total_lp_shares);
        if total_lp_shares > 0 && (reserve_xfg == 0 || reserve_heat == 0) {
            return Err("pool has shares but empty reserves — invalid state".into());
        }
        let shares = if total_lp_shares == 0 {
            // First deposit: isqrt(amountXfg * amountHeat) - MIN_LIQUIDITY.
            isqrt128(amount_xfg as u128 * amount_heat as u128).saturating_sub(1000)
        } else {
            let sa = (amount_xfg as u128 * total_lp_shares as u128 / reserve_xfg as u128) as u64;
            let sb = (amount_heat as u128 * total_lp_shares as u128 / reserve_heat as u128) as u64;
            sa.min(sb)
        };
        if shares == 0 {
            return Err("computed LP shares are zero — amounts below pool ratio tick".into());
        }

        let fee = MINIMUM_FEE;
        let mixin = self.key_mixin(0);
        let keys = self.wallet.lock().unwrap().wallet_keys();
        let selected_xfg = self.select_xfg(amount_xfg + fee)?;
        let xfg_change = selected_xfg.iter().map(|u| u.amount).sum::<u64>() - amount_xfg - fee;
        let (selected_heat, found_heat) = self.select_heat(amount_heat)?;
        let heat_change = found_heat - amount_heat;

        let xfg_decoys = self.key_decoys(&selected_xfg, mixin).await?;
        let mut heat_decoys = Vec::with_capacity(selected_heat.len());
        for entry in &selected_heat {
            heat_decoys.push(self.commitment_decoys(entry).await?);
        }

        let xfg_inputs: Vec<fuego_sdk::transaction_builder::SpendableOutput> =
            selected_xfg.iter().map(|u| u.into()).collect();
        let heat_deposits: Vec<CommitmentDeposit> = selected_heat.iter().map(|d| commitment_deposit(d, 0)).collect();
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
    pub async fn lp_remove(&self, lp_shares: u64, min_xfg: u64, min_heat: u64) -> std::result::Result<String, String> {
        if lp_shares == 0 {
            return Err("shares must be > 0".into());
        }
        let pool = self.daemon.amm_pool_info().await?;
        if pool.total_lp_shares == 0 {
            return Err("pool has no LP shares".into());
        }
        let amount_xfg = (lp_shares as u128 * pool.reserve_xfg as u128 / pool.total_lp_shares as u128) as u64;
        let amount_heat = (lp_shares as u128 * pool.reserve_heat as u128 / pool.total_lp_shares as u128) as u64;
        if amount_xfg < min_xfg || amount_heat < min_heat {
            return Err(format!("withdrawal below minimum: {} XFG / {} HEAT", amount_xfg, amount_heat));
        }

        let fee = MINIMUM_FEE;
        let keys = self.wallet.lock().unwrap().wallet_keys();
        let lp: Vec<CommitmentEntry> = self
            .wallet
            .lock()
            .unwrap()
            .deposits()
            .into_iter()
            .filter(|d| d.term == DEPOSIT_TERM_LP && d.global_index != 0)
            .collect();
        let mut selected = Vec::new();
        let mut found = 0u64;
        for entry in lp {
            if found >= lp_shares {
                break;
            }
            found += entry.amount;
            selected.push(entry);
        }
        // LP change is not representable: require exact coverage.
        if found != lp_shares {
            return Err(format!(
                "LP deposit selection {} does not exactly match shares {} (LP change unsupported)",
                found, lp_shares
            ));
        }

        let mut decoys = Vec::with_capacity(selected.len());
        for entry in &selected {
            decoys.push(self.commitment_decoys(entry).await?);
        }
        let spends: Vec<CommitmentDeposit> = selected.iter().map(|d| commitment_deposit(d, 0)).collect();
        let built = fuego_sdk::transaction_builder::build_lp_remove_transaction(
            &spends,
            &decoys,
            DYNAMAX_RING_SIZES[2],
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

    /// Hearth limit order (place_order): deposit XFG into the pool commit key
    /// with a 0xFB limit-deposit extra.
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
        let mixin = self.key_mixin(0);
        let keys = self.wallet.lock().unwrap().wallet_keys();
        let selected = self.select_xfg(amount + fee)?;

        let mut order_id = [0u8; 32];
        rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut order_id);

        let mut key_data = [0u8; 64];
        key_data[..32].copy_from_slice(&keys.spend_public);
        key_data[32..].copy_from_slice(&keys.view_public);
        let address_hash = fuego_crypto::ring::cn_fast_hash(&key_data);

        let pool_seed = fuego_crypto::ring::cn_fast_hash(b"fuego.hearth.pool.commit.key.v1");
        let pool_scalar = fuego_crypto::ring::hash_to_scalar(&pool_seed);
        let pool_key = fuego_crypto::ring::secret_key_to_public_key(&pool_scalar);

        let decoys = self.key_decoys(&selected, mixin).await?;
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

    /// Lock HEAT into a finite-term CD (WalletGreen heat deposit): HEAT
    /// inputs cover amount + banking fee, the 0.1% banking fee is burned via
    /// the 0xFF TreasuryFund extra, and no other HEAT leaves the transaction
    /// (per-asset rule: outHEAT + fund == inHEAT).
    async fn heat_cd_core(&self, amount: u64, term_blocks: u32, banking_fee: u64) -> std::result::Result<String, String> {
        if amount == 0 {
            return Err("amount must be > 0".into());
        }
        let (min_term, max_term) = self.deposit_term_bounds();
        if term_blocks < min_term || term_blocks > max_term {
            return Err(format!("term must be in {}..={} blocks", min_term, max_term));
        }
        let banking_fee = if banking_fee == 0 { (amount / 1000).max(1) } else { banking_fee };
        let (selected, found) = self.select_heat(amount + banking_fee)?;
        let mut decoys = Vec::with_capacity(selected.len());
        for entry in &selected {
            decoys.push(self.commitment_decoys(entry).await?);
        }

        let keys = self.wallet.lock().unwrap().wallet_keys();
        let heat_change = found - amount - banking_fee;
        let mut commitment_dests = vec![BuildCommitmentDestination { amount, term: term_blocks, view_pub: None }];
        if heat_change > 0 {
            commitment_dests.push(BuildCommitmentDestination { amount: heat_change, term: HEAT_TERM, view_pub: None });
        }
        let mut extra = Vec::new();
        add_treasury_fund_extra(&mut extra, 1 /* HEAT */, banking_fee);

        let spends: Vec<CommitmentDeposit> = selected.iter().map(|d| commitment_deposit(d, 0)).collect();
        let built = build_commitment_spend_transaction(
            &spends,
            &decoys,
            DYNAMAX_RING_SIZES[2],
            &[],
            &commitment_dests,
            &keys.view_public,
            banking_fee,
            &extra,
            &mut rand::thread_rng(),
        )
        .map_err(|e| format!("build: {e}"))?;

        let key_images: Vec<[u8; 32]> = selected.iter().map(|d| d.key_image).collect();
        self.broadcast_built(built, key_images).await
    }

    /// create_cd: HEAT CD with an explicit block term. Returns (tx hash,
    /// cd id, estimated maturity height). The CD is output 0 of its tx.
    pub async fn create_cd(&self, amount: u64, term_blocks: u32) -> std::result::Result<(String, String, u64), String> {
        let tx_hash = self.heat_cd_core(amount, term_blocks, 0).await?;
        let maturity = self.wallet.lock().unwrap().height() + 1 + term_blocks as u64;
        let id = format!("{tx_hash}:0");
        Ok((tx_hash, id, maturity))
    }

    /// heat_cd: HEAT CD with the term expressed in epochs.
    pub async fn heat_cd(&self, amount: u64, epochs: u32, banking_fee: u64) -> std::result::Result<String, String> {
        if epochs == 0 {
            return Err("epochs must be > 0".into());
        }
        let epoch_blocks = if self.testnet {
            suite::TESTNET_EPOCH_DURATION_BLOCKS
        } else {
            suite::EPOCH_DURATION_BLOCKS
        };
        let term = u32::try_from(epochs as u64 * epoch_blocks).map_err(|_| "term overflow".to_string())?;
        self.heat_cd_core(amount, term, banking_fee).await
    }

    /// claim_cd: withdraw mature finite-term CDs with the interest consensus
    /// accepts (WalletGreen::withdrawDeposit / capInterestByPool):
    /// only CDs created at or after v11 earn; base interest is capped by
    /// min(fee pool, CD_APY vault), the Bonus Vault bonus by its backing and
    /// declared per input with 0xD6. The per-transaction totals obey the
    /// same aggregate caps (Blockchain.cpp F-001). Decoys are drawn at or
    /// below each CD's height so the claim matches the youngest-ring-member
    /// cap.
    /// `only` restricts the claim to one CD id; `None` claims every mature CD.
    pub async fn claim_cd(&self, only: Option<&str>) -> std::result::Result<CdClaim, String> {
        let deposits: Vec<CommitmentEntry> = {
            let wallet = self.wallet.lock().unwrap();
            let height = wallet.height();
            wallet
                .deposits()
                .into_iter()
                .filter(|d| d.is_finite_cd() && only.map_or(true, |id| cd_id(d) == id))
                .filter(|d| d.global_index != 0 && d.block_height + d.term as u64 <= height)
                .take(MAX_CLAIM_INPUTS)
                .collect()
        };
        if deposits.is_empty() {
            return Err(match only {
                Some(id) => format!("CD {id} is not owned, not mature, or already claimed"),
                None => "no mature deposits to claim".into(),
            });
        }

        let fee = MINIMUM_FEE;
        let v11 = self.upgrade_height_v11();
        let mut pool_left: Option<u64> = None;
        let mut bonus_left: Option<u64> = None;
        let mut claims: Vec<(u64, u64)> = Vec::with_capacity(deposits.len());
        for d in &deposits {
            if d.block_height < v11 {
                claims.push((0, 0));
                continue;
            }
            let est = self.daemon.estimate_cd_yield(d.amount, d.block_height as u32, d.term).await?;
            if !est.pool_info_present {
                claims.push((est.estimated_interest, 0));
                continue;
            }
            let pool = pool_left.get_or_insert(est.fee_pool_balance.min(est.cd_apy_vault_balance));
            let bv = bonus_left.get_or_insert(est.bonus_vault_balance);
            let (base, bonus) = if est.base_interest > 0 || est.bonus_interest > 0 {
                (est.base_interest, est.claimable_bonus.min(est.bonus_vault_balance).min(*bv))
            } else {
                (est.estimated_interest, 0)
            };
            let total = base.saturating_add(bonus).min(*pool);
            let bonus = bonus.min(total);
            *pool -= total;
            *bv -= bonus;
            claims.push((total, bonus));
        }

        let total: u64 = deposits.iter().zip(&claims).map(|(d, (i, _))| d.amount + i).sum();
        if total <= fee {
            return Err("deposit total below fee".into());
        }

        let mut decoys = Vec::with_capacity(deposits.len());
        for d in &deposits {
            decoys.push(self.commitment_decoys(d).await?);
        }

        let keys = self.wallet.lock().unwrap().wallet_keys();
        let (chunks, dust) = decompose_change(total - fee, DEFAULT_DUST_THRESHOLD);
        let key_dests: Vec<BuildDestination> = chunks
            .into_iter()
            .chain((dust > 0).then_some(dust))
            .map(|amount| BuildDestination { amount, spend_pub: keys.spend_public, view_pub: keys.view_public })
            .collect();

        let mut extra = Vec::new();
        for (i, (_, bonus)) in claims.iter().enumerate() {
            if *bonus > 0 {
                add_cd_bonus_claim_extra(&mut extra, i as u8, *bonus);
            }
        }
        let spends: Vec<CommitmentDeposit> =
            deposits.iter().zip(&claims).map(|(d, (interest, _))| commitment_deposit(d, *interest)).collect();
        let built = build_commitment_spend_transaction(
            &spends,
            &decoys,
            DYNAMAX_RING_SIZES[2],
            &key_dests,
            &[],
            &keys.view_public,
            fee,
            &extra,
            &mut rand::thread_rng(),
        )
        .map_err(|e| format!("build: {e}"))?;

        let key_images: Vec<[u8; 32]> = deposits.iter().map(|d| d.key_image).collect();
        let tx_hash = self.broadcast_built(built, key_images).await?;
        Ok(CdClaim {
            tx_hash,
            cd_ids: deposits.iter().map(cd_id).collect(),
            principal: deposits.iter().map(|d| d.amount).sum(),
            interest: claims.iter().map(|(i, _)| i).sum(),
        })
    }

    /// Owned finite-term CDs.
    pub fn cds(&self) -> Vec<CdView> {
        let wallet = self.wallet.lock().unwrap();
        let height = wallet.height();
        wallet
            .deposits()
            .into_iter()
            .filter(|d| d.is_finite_cd())
            .map(|d| {
                let maturity_height = d.block_height + d.term as u64;
                CdView {
                    cd_id: cd_id(&d),
                    amount: d.amount,
                    term: d.term,
                    deposit_height: d.block_height,
                    maturity_height,
                    matured: d.global_index != 0 && maturity_height <= height,
                }
            })
            .collect()
    }

    /// Claimable interest for a CD today (0 before v11 or when unavailable).
    pub fn cd_interest_estimate_inputs(&self, view: &CdView) -> Option<(DaemonClient, u64, u32, u32)> {
        (view.deposit_height >= self.upgrade_height_v11()).then(|| {
            (self.daemon.clone(), view.amount, view.deposit_height as u32, view.term)
        })
    }

    /// send_heat (WalletGreen::sendHeatV10): transfer HEAT with no fee — the
    /// HEAT-send rule requires inHEAT == outHEAT. The recipient's commitment
    /// output derives with THEIR view key; our change with ours. Carries 0xF9.
    pub async fn send_heat(&self, address: &str, amount: u64) -> std::result::Result<String, String> {
        if amount == 0 {
            return Err("amount must be > 0".into());
        }
        let parsed = fuego_crypto::parse_address_full(address)
            .ok_or_else(|| format!("invalid destination address: {}", address))?;
        if parsed.prefix != self.address_prefix() {
            return Err(format!("address {address} belongs to another network"));
        }
        let (selected, found) = self.select_heat(amount)?;
        let change = found - amount;
        let mut decoys = Vec::with_capacity(selected.len());
        for entry in &selected {
            decoys.push(self.commitment_decoys(entry).await?);
        }

        let keys = self.wallet.lock().unwrap().wallet_keys();
        let mut commitment_dests =
            vec![BuildCommitmentDestination { amount, term: HEAT_TERM, view_pub: Some(parsed.view) }];
        if change > 0 {
            commitment_dests.push(BuildCommitmentDestination { amount: change, term: HEAT_TERM, view_pub: None });
        }
        let mut extra = Vec::new();
        fuego_sdk::serialization::add_heat_send_auth_extra(&mut extra, amount);

        let spends: Vec<CommitmentDeposit> = selected.iter().map(|d| commitment_deposit(d, 0)).collect();
        let built = build_commitment_spend_transaction(
            &spends,
            &decoys,
            DYNAMAX_RING_SIZES[2],
            &[],
            &commitment_dests,
            &keys.view_public,
            0,
            &extra,
            &mut rand::thread_rng(),
        )
        .map_err(|e| format!("build: {e}"))?;

        let key_images: Vec<[u8; 32]> = selected.iter().map(|d| d.key_image).collect();
        self.broadcast_built(built, key_images).await
    }

    /// Register an @alias (TX_EXTRA_ALIAS 0xEA). Mainnet pays
    /// ALIAS_REGISTRATION_FEE plus random dust (≤ ALIAS_REGISTRATION_FEE_MAX_RANDOM)
    /// to FUEGO_DEV_FUND_ADDRESS; testnet consensus waives the fee.
    pub async fn register_alias(&self, alias: &str) -> std::result::Result<String, String> {
        let alias = alias.trim().trim_start_matches('@').to_ascii_lowercase();
        if !fuego_sdk::alias::is_valid_regular_alias(&alias) {
            return Err("alias must be exactly 8 characters from a-z, 0-9 and &".into());
        }
        if let Ok(existing) = self.daemon.get_alias(&alias).await {
            if existing.found {
                return Err(format!("@{} is already registered", alias));
            }
        }
        let keys = self.wallet.lock().unwrap().wallet_keys();
        let owner = self.primary_address_string();
        let extra = fuego_sdk::alias::alias_registration_extra(&alias, &owner, &keys.spend_public, &keys.view_public)
            .map_err(|e| e.to_string())?;
        let mut dests = Vec::new();
        if !self.testnet {
            let dust = rand::thread_rng().gen_range(0..=suite::ALIAS_REGISTRATION_FEE_MAX_RANDOM);
            dests.push((suite::FUEGO_DEV_FUND_ADDRESS.to_string(), suite::ALIAS_REGISTRATION_FEE + dust));
        }
        self.send_keys(&dests, MINIMUM_FEE, self.key_mixin(0), &extra, 0).await
    }

    /// walletd createIntegratedAddress: encode_addr(prefix, hex(pid) || keys).
    /// Uses this network's prefix (the suite always uses the mainnet one).
    pub fn create_integrated(&self, address: Option<&str>, payment_id: &str) -> std::result::Result<String, String> {
        let pid = parse_payment_id(payment_id)?;
        let (spend, view) = match address.filter(|a| !a.is_empty()) {
            Some(a) => {
                let parsed = fuego_crypto::parse_address_full(a).ok_or_else(|| format!("invalid address: {a}"))?;
                if parsed.payment_id.is_some() {
                    return Err("address is already integrated".into());
                }
                (parsed.spend, parsed.view)
            }
            None => {
                let keys = self.wallet.lock().unwrap().wallet_keys();
                (keys.spend_public, keys.view_public)
            }
        };
        Ok(fuego_crypto::make_integrated_address(self.address_prefix(), &pid, &spend, &view).0)
    }

    /// get_tx_proof: a "ProofV1" payment proof for one of our outgoing
    /// transactions (WalletLegacy::getTxProof format).
    pub async fn get_tx_proof(&self, tx_hash: &str, address: &str) -> std::result::Result<String, String> {
        let (_recv_spend, recv_view) =
            fuego_crypto::parse_address(address).ok_or_else(|| format!("invalid address: {}", address))?;

        let serialized_hex = self
            .db
            .get(format!("txs:{}", tx_hash).as_bytes())
            .ok()
            .flatten()
            .map(|b| String::from_utf8_lossy(&b).to_string())
            .ok_or_else(|| format!("transaction {} not found (only locally-sent txs are provable)", tx_hash))?;
        let serialized = hex::decode(&serialized_hex).map_err(|e| format!("stored tx decode failed: {e}"))?;
        let prefix =
            fuego_sdk::serialization::parse_prefix(&serialized).map_err(|e| format!("stored tx parse failed: {e}"))?;

        let keys = self.wallet.lock().unwrap().wallet_keys();
        let r = fuego_sdk::transaction_builder::recover_tx_secret(&prefix.inputs, &keys.view_secret);

        // R = r*G; D = r*A (raw, no cofactor).
        let mut r_p3 = fuego_crypto::ref10::GeP3::default();
        fuego_crypto::ref10::ge_scalarmult_base(&mut r_p3, &r);
        let mut r_pub = [0u8; 32];
        fuego_crypto::ref10::ge_p3_tobytes(&mut r_pub, &r_p3);
        let d = fuego_crypto::ring::raw_scalarmult_key(&recv_view, &r).ok_or("tx proof derivation failed")?;

        let prefix_hash = fuego_crypto::cn_fast_hash(&fuego_sdk::serialization::serialize_prefix(&prefix));
        let sig = fuego_crypto::ring::generate_tx_proof(&prefix_hash, &r, &r_pub, &recv_view, &d, &mut rand::thread_rng())
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

    pub fn balance_breakdown(&self) -> BalanceBreakdown {
        self.wallet.lock().unwrap().balance_breakdown()
    }

    pub fn sync_status(&self) -> SyncStatus {
        let current = self.wallet.lock().unwrap().height();
        let target = self.known_height.load(Ordering::Relaxed);
        SyncStatus {
            current_height: current,
            target_height: target,
            is_syncing: target > current + 1,
            last_sync_time: None,
        }
    }

    pub fn is_testnet(&self) -> bool {
        self.testnet
    }

    pub async fn get_transactions(&self, limit: usize) -> Vec<HistoryEntry> {
        self.wallet.lock().unwrap().get_transactions(limit)
    }

    pub async fn get_keypair(&self, index: u32) -> Keypair {
        self.wallet.lock().unwrap().get_keypair(index)
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

        let rate = |a: u64| a * suite::SWAP_FEE_RATE_BPS / suite::SWAP_FEE_RATE_DIVISOR;
        let total_locked = secret.amount + rate(secret.amount);
        let taker_gross = secret.amount - rate(secret.amount) + MINIMUM_FEE;
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
            .send_keys(&dests, MINIMUM_FEE, self.key_mixin(0), &[], 0)
            .await
            .map_err(SdkError::Vault)?;
        secret.secret.iter_mut().for_each(|b| *b = 0);
        secret.pre_sig.iter_mut().for_each(|b| *b = 0);
        let mut out = [0u8; 32];
        hex::decode_to_slice(&tx_hash, &mut out).map_err(|e| SdkError::Vault(e.to_string()))?;
        Ok(out)
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
        for pair in [3u8, 6, 8, 9, 10] {
            assert_eq!(
                afk_hash_lock(pair, &T),
                "630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd"
            );
        }
        for pair in [0u8, 1, 4, 5, 7, 11] {
            assert_eq!(
                afk_hash_lock(pair, &T),
                "8ae1aa597fa146ebd3aa2ceddf360668dea5e526567e92b0321816a4e895bd2d"
            );
        }
    }

    #[test]
    fn hashlock_never_equals_hash_of_adaptor_point() {
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

    #[test]
    fn dynamax_matches_suite_ring_policy() {
        assert_eq!(dynamax_ring_size(40, false), Some(32));
        assert_eq!(dynamax_ring_size(20, false), Some(16));
        assert_eq!(dynamax_ring_size(8, false), Some(8));
        // Mainnet never builds a ring consensus will reject.
        assert_eq!(dynamax_ring_size(7, false), None);
        assert!(suite::MIN_TX_MIXIN_SIZE_V10 as usize <= DYNAMAX_RING_SIZES[2]);
        // Testnet bootstraps with whatever exists.
        assert_eq!(dynamax_ring_size(3, true), Some(3));
        assert_eq!(dynamax_ring_size(0, true), None);
    }
}
