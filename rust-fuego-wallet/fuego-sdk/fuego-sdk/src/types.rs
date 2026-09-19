use serde::{Deserialize, Serialize};
use zeroize::Zeroize;

// ── Swap / Orderbook types ────────────────────────────────────────

/// Trading pair for swap offers.
///
/// Mirrors `XfgSwap::SwapPair` in fuego-suite
/// `src/SwapDaemon/SwapTypes.h:77` — ids 0-28, no gaps. Previously this
/// enum stopped at 11, so two thirds of the daemon's pairs had no
/// representation and `from_id` rejected them.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub enum SwapPair {
    XfgSol = 0,
    XfgEth = 1,
    XfgXmr = 2,
    XfgBch = 3,
    XfgArb = 4,
    XfgBase = 5,
    XfgKmd = 6,
    XfgBnb = 7,
    XfgDcr = 8,
    XfgBtc = 9,
    XfgLtc = 10,
    XfgPoly = 11,
    XfgGleec = 12,
    XfgRhc = 13,
    XfgAvax = 14,
    XfgCro = 15,
    XfgBob = 16,
    XfgSia = 17,
    XfgUni = 18,
    XfgXpl = 19,
    XfgDoge = 20,
    XfgDash = 21,
    XfgZec = 22,
    XfgPls = 23,
    XfgZano = 24,
    XfgMon = 25,
    XfgOp = 26,
    XfgTon = 27,
    XfgDot = 28,
}

impl SwapPair {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::XfgSol => "XFG/SOL",
            Self::XfgEth => "XFG/ETH",
            Self::XfgXmr => "XFG/XMR",
            Self::XfgBch => "XFG/BCH",
            Self::XfgArb => "XFG/ARB",
            Self::XfgBase => "XFG/BASE",
            Self::XfgKmd => "XFG/KMD",
            Self::XfgBnb => "XFG/BNB",
            Self::XfgDcr => "XFG/DCR",
            Self::XfgBtc => "XFG/BTC",
            Self::XfgLtc => "XFG/LTC",
            Self::XfgPoly => "XFG/POLY",
            Self::XfgGleec => "XFG/GLEEC",
            Self::XfgRhc => "XFG/RHC",
            Self::XfgAvax => "XFG/AVAX",
            Self::XfgCro => "XFG/CRO",
            Self::XfgBob => "XFG/BOB",
            Self::XfgSia => "XFG/SIA",
            Self::XfgUni => "XFG/UNI",
            Self::XfgXpl => "XFG/XPL",
            Self::XfgDoge => "XFG/DOGE",
            Self::XfgDash => "XFG/DASH",
            Self::XfgZec => "XFG/ZEC",
            Self::XfgPls => "XFG/PLS",
            Self::XfgZano => "XFG/ZANO",
            Self::XfgMon => "XFG/MON",
            Self::XfgOp => "XFG/OP",
            Self::XfgTon => "XFG/TON",
            Self::XfgDot => "XFG/DOT",
        }
    }

    /// Display ticker.
    pub fn ticker(&self) -> &'static str {
        match self {
            Self::XfgSol => "SOL",
            Self::XfgEth => "ETH",
            Self::XfgXmr => "XMR",
            Self::XfgBch => "BCH",
            Self::XfgArb => "ARB",
            Self::XfgBase => "BASE",
            Self::XfgKmd => "KMD",
            Self::XfgBnb => "BNB",
            Self::XfgDcr => "DCR",
            Self::XfgBtc => "BTC",
            Self::XfgLtc => "LTC",
            Self::XfgPoly => "POLY",
            Self::XfgGleec => "GLEEC",
            Self::XfgRhc => "RHC",
            Self::XfgAvax => "AVAX",
            Self::XfgCro => "CRO",
            Self::XfgBob => "BOB",
            Self::XfgSia => "SIA",
            Self::XfgUni => "UNI",
            Self::XfgXpl => "XPL",
            Self::XfgDoge => "DOGE",
            Self::XfgDash => "DASH",
            Self::XfgZec => "ZEC",
            Self::XfgPls => "PLS",
            Self::XfgZano => "ZANO",
            Self::XfgMon => "MON",
            Self::XfgOp => "OP",
            Self::XfgTon => "TON",
            Self::XfgDot => "DOT",
        }
    }

    /// The exact string `swapPairFromString` accepts
    /// (`src/SwapDaemon/SwapTypes.cpp:30`). For six pairs this is NOT the
    /// display ticker — sending `RHC`, `UNI`, `XPL`, `PLS` or `MON` is
    /// rejected as "Unknown swap pair", and `KMD_SPV`/`POLYGON` are the
    /// canonical forms of `KMD`/`POLY`.
    pub fn daemon_name(&self) -> &'static str {
        match self {
            Self::XfgSol => "SOL",
            Self::XfgEth => "ETH",
            Self::XfgXmr => "XMR",
            Self::XfgBch => "BCH",
            Self::XfgArb => "ARB",
            Self::XfgBase => "BASE",
            Self::XfgKmd => "KMD_SPV",
            Self::XfgBnb => "BNB",
            Self::XfgDcr => "DCR",
            Self::XfgBtc => "BTC",
            Self::XfgLtc => "LTC",
            Self::XfgPoly => "POLYGON",
            Self::XfgGleec => "GLEEC",
            Self::XfgRhc => "ROBINHOOD",
            Self::XfgAvax => "AVAX",
            Self::XfgCro => "CRO",
            Self::XfgBob => "BOB",
            Self::XfgSia => "SIA",
            Self::XfgUni => "UNICHAIN",
            Self::XfgXpl => "PLASMA",
            Self::XfgDoge => "DOGE",
            Self::XfgDash => "DASH",
            Self::XfgZec => "ZEC",
            Self::XfgPls => "PULSEX",
            Self::XfgZano => "ZANO",
            Self::XfgMon => "MONAD",
            Self::XfgOp => "OPTIMISM",
            Self::XfgTon => "TON",
            Self::XfgDot => "DOT",
        }
    }

    pub fn chain_type(&self) -> crate::chain::ChainType {
        match self {
            Self::XfgSol => crate::chain::ChainType::Solana,
            Self::XfgEth => crate::chain::ChainType::Ethereum,
            Self::XfgXmr => crate::chain::ChainType::Monero,
            Self::XfgBch => crate::chain::ChainType::BitcoinCash,
            Self::XfgArb => crate::chain::ChainType::Arbitrum,
            Self::XfgBase => crate::chain::ChainType::Base,
            Self::XfgKmd => crate::chain::ChainType::Komodo,
            Self::XfgBnb => crate::chain::ChainType::Bnb,
            Self::XfgDcr => crate::chain::ChainType::Decred,
            Self::XfgBtc => crate::chain::ChainType::Bitcoin,
            Self::XfgLtc => crate::chain::ChainType::Litecoin,
            Self::XfgPoly => crate::chain::ChainType::Polygon,
            Self::XfgGleec => crate::chain::ChainType::Gleec,
            Self::XfgRhc => crate::chain::ChainType::Robinhood,
            Self::XfgAvax => crate::chain::ChainType::Avalanche,
            Self::XfgCro => crate::chain::ChainType::Cronos,
            Self::XfgBob => crate::chain::ChainType::Bob,
            Self::XfgSia => crate::chain::ChainType::Sia,
            Self::XfgUni => crate::chain::ChainType::Unichain,
            Self::XfgXpl => crate::chain::ChainType::Plasma,
            Self::XfgDoge => crate::chain::ChainType::Dogecoin,
            Self::XfgDash => crate::chain::ChainType::Dash,
            Self::XfgZec => crate::chain::ChainType::Zcash,
            Self::XfgPls => crate::chain::ChainType::PulseChain,
            Self::XfgZano => crate::chain::ChainType::Zano,
            Self::XfgMon => crate::chain::ChainType::Monad,
            Self::XfgOp => crate::chain::ChainType::Optimism,
            Self::XfgTon => crate::chain::ChainType::Ton,
            Self::XfgDot => crate::chain::ChainType::Polkadot,
        }
    }

    /// True when `SwapDaemon.cpp` never calls `registerChain` for this pair —
    /// the client source exists but is staged, and the daemon logs
    /// "… is staged — not yet registered". Offering such a pair produces a
    /// swap the daemon refuses to run.
    pub fn is_staged(&self) -> bool {
        match self {
            Self::XfgSia => true,
            Self::XfgZano => true,
            Self::XfgTon => true,
            Self::XfgDot => true,
            _ => false,
        }
    }

    /// Pairs the daemon actually registers a client for (25 of 29).
    pub fn registered() -> Vec<SwapPair> {
        Self::all().iter().copied().filter(|p| !p.is_staged()).collect()
    }

    pub fn all() -> &'static [SwapPair] {
        &[
            Self::XfgSol,
            Self::XfgEth,
            Self::XfgXmr,
            Self::XfgBch,
            Self::XfgArb,
            Self::XfgBase,
            Self::XfgKmd,
            Self::XfgBnb,
            Self::XfgDcr,
            Self::XfgBtc,
            Self::XfgLtc,
            Self::XfgPoly,
            Self::XfgGleec,
            Self::XfgRhc,
            Self::XfgAvax,
            Self::XfgCro,
            Self::XfgBob,
            Self::XfgSia,
            Self::XfgUni,
            Self::XfgXpl,
            Self::XfgDoge,
            Self::XfgDash,
            Self::XfgZec,
            Self::XfgPls,
            Self::XfgZano,
            Self::XfgMon,
            Self::XfgOp,
            Self::XfgTon,
            Self::XfgDot,
        ]
    }

    pub fn from_id(id: u8) -> Option<Self> {
        match id {
            0 => Some(Self::XfgSol),
            1 => Some(Self::XfgEth),
            2 => Some(Self::XfgXmr),
            3 => Some(Self::XfgBch),
            4 => Some(Self::XfgArb),
            5 => Some(Self::XfgBase),
            6 => Some(Self::XfgKmd),
            7 => Some(Self::XfgBnb),
            8 => Some(Self::XfgDcr),
            9 => Some(Self::XfgBtc),
            10 => Some(Self::XfgLtc),
            11 => Some(Self::XfgPoly),
            12 => Some(Self::XfgGleec),
            13 => Some(Self::XfgRhc),
            14 => Some(Self::XfgAvax),
            15 => Some(Self::XfgCro),
            16 => Some(Self::XfgBob),
            17 => Some(Self::XfgSia),
            18 => Some(Self::XfgUni),
            19 => Some(Self::XfgXpl),
            20 => Some(Self::XfgDoge),
            21 => Some(Self::XfgDash),
            22 => Some(Self::XfgZec),
            23 => Some(Self::XfgPls),
            24 => Some(Self::XfgZano),
            25 => Some(Self::XfgMon),
            26 => Some(Self::XfgOp),
            27 => Some(Self::XfgTon),
            28 => Some(Self::XfgDot),
            _ => None,
        }
    }

    /// Accepts the display ticker, the daemon name, and the daemon's own
    /// aliases (`KMD`, `POLY`, `SC`, `PULS`, `OP`, `POLKADOT`).
    pub fn from_name(name: &str) -> Option<Self> {
        match name.trim().to_uppercase().as_str() {
            "SOL" => Some(Self::XfgSol),
            "ETH" => Some(Self::XfgEth),
            "XMR" => Some(Self::XfgXmr),
            "BCH" => Some(Self::XfgBch),
            "ARB" => Some(Self::XfgArb),
            "BASE" => Some(Self::XfgBase),
            "KMD" | "KMD_SPV" => Some(Self::XfgKmd),
            "BNB" => Some(Self::XfgBnb),
            "DCR" => Some(Self::XfgDcr),
            "BTC" => Some(Self::XfgBtc),
            "LTC" => Some(Self::XfgLtc),
            "POLY" | "POLYGON" => Some(Self::XfgPoly),
            "GLEEC" => Some(Self::XfgGleec),
            "RHC" | "ROBINHOOD" => Some(Self::XfgRhc),
            "AVAX" => Some(Self::XfgAvax),
            "CRO" => Some(Self::XfgCro),
            "BOB" => Some(Self::XfgBob),
            "SC" | "SIA" => Some(Self::XfgSia),
            "UNI" | "UNICHAIN" => Some(Self::XfgUni),
            "PLASMA" | "XPL" => Some(Self::XfgXpl),
            "DOGE" => Some(Self::XfgDoge),
            "DASH" => Some(Self::XfgDash),
            "ZEC" => Some(Self::XfgZec),
            "PLS" | "PULS" | "PULSEX" => Some(Self::XfgPls),
            "ZANO" => Some(Self::XfgZano),
            "MON" | "MONAD" => Some(Self::XfgMon),
            "OP" | "OPTIMISM" => Some(Self::XfgOp),
            "TON" => Some(Self::XfgTon),
            "DOT" | "POLKADOT" => Some(Self::XfgDot),
            _ => None,
        }
    }
}

impl std::fmt::Display for SwapPair {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

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
