use serde::{Deserialize, Serialize};
use zeroize::Zeroize;

// ── Swap / Orderbook types ────────────────────────────────────────

// Generated from the pinned suite SwapPair. Do not hand-edit the arms.
include!("swap_pair_generated.rs");

/// Swap offer on the orderbook.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SwapOffer {
    pub offer_id: String,
    pub maker_pubkey: String,
    pub pair: SwapPair,
    pub sell_xfg: bool,
    pub amount: String,
    pub price: String,
    pub created_at: u64,
    pub expires_at: u64,
}

/// Signed swap offer for submission.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedOffer {
    pub offer: SwapOffer,
    pub signature: String,
}

/// Price data for a trading pair.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SwapPriceResponse {
    pub pair: SwapPair,
    pub bid: String,
    pub ask: String,
    pub last: String,
    pub volume_24h: String,
    pub change_24h: String,
    #[serde(default)]
    pub status: String,
}

/// Historical trade record.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SwapTrade {
    pub trade_id: String,
    pub pair: SwapPair,
    pub sell_xfg: bool,
    pub amount: String,
    pub price: String,
    pub timestamp: u64,
}

/// Active swap status.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SwapStatus {
    pub swap_id: String,
    pub state: SwapState,
    pub pair: SwapPair,
    pub amount: String,
    pub maker_pubkey: String,
    pub taker_pubkey: Option<String>,
    pub created_at: u64,
    pub updated_at: u64,
}

/// Swap state machine states.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum SwapState {
    /// Maker has posted offer.
    Open,
    /// Taker has matched an offer.
    Matched,
    /// Maker has locked funds (adaptor sig sent).
    MakerLocked,
    /// Taker has locked funds (adaptor sig sent).
    TakerLocked,
    /// Maker has revealed preimage.
    MakerRevealed,
    /// Swap completed successfully.
    Completed,
    /// Swap was cancelled or expired.
    Cancelled,
}

/// Orderbook state snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrderBookState {
    pub bids: Vec<OrderLevel>,
    pub asks: Vec<OrderLevel>,
    pub last_price: String,
    pub volume_24h: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrderLevel {
    pub price: String,
    pub amount: String,
    pub count: u32,
}

/// Fuego price data.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FuegoPrice {
    pub usd: String,
    pub btc: String,
    pub eth: String,
    pub market_cap: String,
    #[serde(default)]
    pub status: String,
}

// ── Certificate of Deposit types ──────────────────────────────────

/// CD listing on the market.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CdListing {
    pub cd_id: String,
    pub owner_pubkey: String,
    pub amount: u64,
    pub term_days: u32,
    pub apy: String,
    pub created_at: u64,
    pub expires_at: u64,
}

/// CD offer for purchase.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CdOffer {
    pub offer_id: String,
    pub cd_id: String,
    pub ask_price: String,
    pub created_at: u64,
}

/// User's CD record.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MyCd {
    pub cd_id: String,
    pub amount: u64,
    pub term_days: u32,
    pub apy: String,
    pub created_at: u64,
    pub matures_at: u64,
    pub is_active: bool,
}

/// Fuego address (Base58 CryptoNote format)
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct Address(pub String);

impl Address {
    pub fn new(addr: impl Into<String>) -> Self {
        Self(addr.into())
    }
}

impl std::fmt::Display for Address {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl From<&str> for Address {
    fn from(s: &str) -> Self {
        Self(s.to_string())
    }
}

impl From<String> for Address {
    fn from(s: String) -> Self {
        Self(s)
    }
}

/// Public key (32 bytes Ed25519)
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct PublicKey(pub [u8; 32]);

impl zeroize::Zeroize for PublicKey {
    fn zeroize(&mut self) {
        self.0.zeroize();
    }
}

/// Secret key (32 bytes)
#[derive(Debug, Zeroize)]
#[zeroize(drop)]
pub struct SecretKey(pub(crate) [u8; 32]);

impl SecretKey {
    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

/// Keypair for signing
#[derive(Debug, Zeroize)]
#[zeroize(drop)]
pub struct Keypair {
    pub secret: SecretKey,
    pub public: PublicKey,
}

/// Block header
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockHeader {
    pub height: u64,
    pub hash: [u8; 32],
    pub prev_hash: [u8; 32],
    pub timestamp: u64,
    pub tx_count: u32,
}

/// Block with transactions
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Block {
    pub header: BlockHeader,
    pub transactions: Vec<Transaction>,
}

/// Transaction
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Transaction {
    pub hash: [u8; 32],
    pub inputs: Vec<TxInput>,
    pub outputs: Vec<TxOutput>,
    pub extra: Vec<u8>,
    pub fee: u64,
}

/// Transaction input
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TxInput {
    pub prev_tx_hash: [u8; 32],
    pub prev_output_index: u32,
    pub signature: Vec<u8>,
}

/// Transaction output
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TxOutput {
    pub amount: u64,
    pub pubkey: [u8; 32],
}

/// UTXO (Unspent Transaction Output)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Utxo {
    pub tx_hash: [u8; 32],
    pub output_index: u32,
    pub amount: u64,
    pub pubkey: [u8; 32],
    pub height: u64,
}

/// Network sync status
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncStatus {
    pub current_height: u64,
    pub target_height: u64,
    pub is_syncing: bool,
    pub last_sync_time: Option<u64>,
}

/// Node configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeConfig {
    pub data_dir: String,
    pub network: NetworkType,
    pub max_peers: usize,
    pub sync_interval_secs: u64,
    pub enable_seeding: bool,
}

impl Default for NodeConfig {
    fn default() -> Self {
        Self {
            data_dir: "./fuego-data".to_string(),
            network: NetworkType::Mainnet,
            max_peers: 50,
            sync_interval_secs: 30,
            enable_seeding: false,
        }
    }
}

/// Network type
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub enum NetworkType {
    Mainnet,
    Testnet,
    Stagenet,
}

/// Balance breakdown
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Balance {
    pub confirmed: u64,
    pub pending: u64,
    pub immature: u64,
}

impl Balance {
    pub fn total(&self) -> u64 {
        self.confirmed.saturating_add(self.pending).saturating_add(self.immature)
    }
}

/// Transaction builder
pub struct TxBuilder {
    inputs: Vec<TxInput>,
    outputs: Vec<TxOutput>,
    extra: Vec<u8>,
}

impl Default for TxBuilder {
    fn default() -> Self {
        Self::new()
    }
}

impl TxBuilder {
    pub fn new() -> Self {
        Self {
            inputs: Vec::new(),
            outputs: Vec::new(),
            extra: Vec::new(),
        }
    }

    pub fn add_input(mut self, input: TxInput) -> Self {
        self.inputs.push(input);
        self
    }

    pub fn add_output(mut self, amount: u64, pubkey: [u8; 32]) -> Self {
        self.outputs.push(TxOutput { amount, pubkey });
        self
    }

    pub fn set_extra(mut self, extra: Vec<u8>) -> Self {
        self.extra = extra;
        self
    }

    pub fn build(self) -> Transaction {
        Transaction {
            hash: [0; 32],
            inputs: self.inputs,
            outputs: self.outputs,
            extra: self.extra,
            fee: 0,
        }
    }
}
