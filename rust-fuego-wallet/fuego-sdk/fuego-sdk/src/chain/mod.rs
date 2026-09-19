pub mod bitcoin;
pub mod btc_rpc;
pub mod evm;
pub mod evm_rpc;
pub mod mpt;

pub use bitcoin::BitcoinChain;
pub use btc_rpc::BtcRpcClient;
pub use evm::EvmChain;
pub use evm_rpc::EvmRpcClient;

use crate::error::Result;
use serde::{Deserialize, Serialize};

/// Chains the swap daemon can carry a counterparty leg on, plus Fuego.
///
/// One variant per `XfgSwap::SwapPair` (fuego-suite
/// `src/SwapDaemon/SwapTypes.h:77`). This enum previously listed 13 chains
/// against the daemon's 29, so `from_symbol` returned `None` for two thirds
/// of them and `EvmChain::new` rejected every EVM chain added after Polygon.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ChainType {
    Fuego,
    Solana,
    Ethereum,
    Monero,
    BitcoinCash,
    Arbitrum,
    Base,
    Komodo,
    Bnb,
    Decred,
    Bitcoin,
    Litecoin,
    Polygon,
    Gleec,
    Robinhood,
    Avalanche,
    Cronos,
    Bob,
    Sia,
    Unichain,
    Plasma,
    Dogecoin,
    Dash,
    Zcash,
    PulseChain,
    Zano,
    Monad,
    Optimism,
    Ton,
    Polkadot,
}

impl ChainType {
    pub fn name(&self) -> &'static str {
        match self {
            Self::Fuego => "Fuego",
            Self::Solana => "Solana",
            Self::Ethereum => "Ethereum",
            Self::Monero => "Monero",
            Self::BitcoinCash => "Bitcoin Cash",
            Self::Arbitrum => "Arbitrum",
            Self::Base => "Base",
            Self::Komodo => "Komodo",
            Self::Bnb => "BNB Chain",
            Self::Decred => "Decred",
            Self::Bitcoin => "Bitcoin",
            Self::Litecoin => "Litecoin",
            Self::Polygon => "Polygon",
            Self::Gleec => "Gleec Chain",
            Self::Robinhood => "Robinhood Chain",
            Self::Avalanche => "Avalanche",
            Self::Cronos => "Cronos",
            Self::Bob => "BOB",
            Self::Sia => "Sia",
            Self::Unichain => "Unichain",
            Self::Plasma => "Plasma",
            Self::Dogecoin => "Dogecoin",
            Self::Dash => "Dash",
            Self::Zcash => "Zcash",
            Self::PulseChain => "PulseChain",
            Self::Zano => "Zano",
            Self::Monad => "Monad",
            Self::Optimism => "Optimism",
            Self::Ton => "TON",
            Self::Polkadot => "Polkadot",
        }
    }

    pub fn symbol(&self) -> &'static str {
        match self {
            Self::Fuego => "XFG",
            Self::Solana => "SOL",
            Self::Ethereum => "ETH",
            Self::Monero => "XMR",
            Self::BitcoinCash => "BCH",
            Self::Arbitrum => "ARB",
            Self::Base => "BASE",
            Self::Komodo => "KMD",
            Self::Bnb => "BNB",
            Self::Decred => "DCR",
            Self::Bitcoin => "BTC",
            Self::Litecoin => "LTC",
            Self::Polygon => "POLY",
            Self::Gleec => "GLEEC",
            Self::Robinhood => "RHC",
            Self::Avalanche => "AVAX",
            Self::Cronos => "CRO",
            Self::Bob => "BOB",
            Self::Sia => "SIA",
            Self::Unichain => "UNI",
            Self::Plasma => "XPL",
            Self::Dogecoin => "DOGE",
            Self::Dash => "DASH",
            Self::Zcash => "ZEC",
            Self::PulseChain => "PLS",
            Self::Zano => "ZANO",
            Self::Monad => "MON",
            Self::Optimism => "OP",
            Self::Ton => "TON",
            Self::Polkadot => "DOT",
        }
    }

    /// Base-unit decimals. Used to scale an on-chain amount; getting it wrong
    /// is a power-of-ten error in a value the counterparty verifies.
    pub fn decimals(&self) -> u8 {
        match self {
            Self::Fuego => 7,
            Self::Solana => 9,
            Self::Ethereum => 18,
            Self::Monero => 12,
            Self::BitcoinCash => 8,
            Self::Arbitrum => 18,
            Self::Base => 18,
            Self::Komodo => 8,
            Self::Bnb => 18,
            Self::Decred => 8,
            Self::Bitcoin => 8,
            Self::Litecoin => 8,
            Self::Polygon => 18,
            Self::Gleec => 18,
            Self::Robinhood => 18,
            Self::Avalanche => 18,
            Self::Cronos => 18,
            Self::Bob => 18,
            Self::Sia => 24,
            Self::Unichain => 18,
            Self::Plasma => 18,
            Self::Dogecoin => 8,
            Self::Dash => 8,
            Self::Zcash => 8,
            Self::PulseChain => 18,
            Self::Zano => 12,
            Self::Monad => 18,
            Self::Optimism => 18,
            Self::Ton => 9,
            Self::Polkadot => 10,
        }
    }

    pub fn is_bitcoin_family(&self) -> bool {
        matches!(self, Self::BitcoinCash | Self::Komodo | Self::Decred | Self::Bitcoin | Self::Litecoin | Self::Dogecoin | Self::Dash | Self::Zcash)
    }

    pub fn is_evm(&self) -> bool {
        matches!(self, Self::Ethereum | Self::Arbitrum | Self::Base | Self::Bnb | Self::Polygon | Self::Gleec | Self::Robinhood | Self::Avalanche | Self::Cronos | Self::Bob | Self::Unichain | Self::Plasma | Self::PulseChain | Self::Monad | Self::Optimism)
    }

    /// Canonical EVM mainnet chain id, or `None` for a non-EVM chain.
    ///
    /// Values match `chains.yaml`, which the wallet's RPC layer is generated
    /// from. Monad is **143**; fuego-suite's `ChainClientConfig.cpp` defaults
    /// `monad_chain_id` to 185, which is wrong and makes the wrong-network
    /// guard reject every Monad proof. Fix it there, not here.
    pub fn evm_chain_id(&self) -> Option<u64> {
        match self {
            Self::Ethereum => Some(1),
            Self::Arbitrum => Some(42161),
            Self::Base => Some(8453),
            Self::Bnb => Some(56),
            Self::Polygon => Some(137),
            Self::Gleec => Some(11169),
            Self::Robinhood => Some(4663),
            Self::Avalanche => Some(43114),
            Self::Cronos => Some(25),
            Self::Bob => Some(60808),
            Self::Unichain => Some(130),
            Self::Plasma => Some(9745),
            Self::PulseChain => Some(369),
            Self::Monad => Some(143),
            Self::Optimism => Some(10),
            _ => None,
        }
    }

    /// EVM **testnet** chain id where one is recorded.
    ///
    /// Sparse on purpose: only chains whose testnet id has been confirmed
    /// appear. `None` means "not recorded here", not "no testnet" — so a
    /// caller must treat it as unknown rather than as a mainnet-only chain.
    pub fn evm_testnet_chain_id(&self) -> Option<u64> {
        match self {
            Self::Monad => Some(10143),
            _ => None,
        }
    }

    /// True when `id` is a chain id this type accepts — mainnet, or a
    /// recorded testnet when `allow_testnet`.
    pub fn accepts_chain_id(&self, id: u64, allow_testnet: bool) -> bool {
        if self.evm_chain_id() == Some(id) {
            return true;
        }
        allow_testnet && self.evm_testnet_chain_id() == Some(id)
    }

    pub fn all() -> &'static [ChainType] {
        &[
            Self::Fuego,
            Self::Solana,
            Self::Ethereum,
            Self::Monero,
            Self::BitcoinCash,
            Self::Arbitrum,
            Self::Base,
            Self::Komodo,
            Self::Bnb,
            Self::Decred,
            Self::Bitcoin,
            Self::Litecoin,
            Self::Polygon,
            Self::Gleec,
            Self::Robinhood,
            Self::Avalanche,
            Self::Cronos,
            Self::Bob,
            Self::Sia,
            Self::Unichain,
            Self::Plasma,
            Self::Dogecoin,
            Self::Dash,
            Self::Zcash,
            Self::PulseChain,
            Self::Zano,
            Self::Monad,
            Self::Optimism,
            Self::Ton,
            Self::Polkadot,
        ]
    }

    /// Accepts tickers and the daemon's own aliases.
    pub fn from_symbol(sym: &str) -> Option<Self> {
        match sym.trim().to_uppercase().as_str() {
            "XFG" => Some(Self::Fuego),
            "SOL" => Some(Self::Solana),
            "ETH" => Some(Self::Ethereum),
            "XMR" => Some(Self::Monero),
            "BCH" => Some(Self::BitcoinCash),
            "ARB" => Some(Self::Arbitrum),
            "BASE" => Some(Self::Base),
            "KMD" | "KMD_SPV" => Some(Self::Komodo),
            "BNB" | "BSC" => Some(Self::Bnb),
            "DCR" => Some(Self::Decred),
            "BTC" => Some(Self::Bitcoin),
            "LTC" => Some(Self::Litecoin),
            "POLY" | "POLYGON" => Some(Self::Polygon),
            "GLEEC" => Some(Self::Gleec),
            "RHC" | "ROBINHOOD" => Some(Self::Robinhood),
            "AVAX" => Some(Self::Avalanche),
            "CRO" => Some(Self::Cronos),
            "BOB" => Some(Self::Bob),
            "SC" | "SIA" => Some(Self::Sia),
            "UNI" | "UNICHAIN" => Some(Self::Unichain),
            "PLASMA" | "XPL" => Some(Self::Plasma),
            "DOGE" => Some(Self::Dogecoin),
            "DASH" => Some(Self::Dash),
            "ZEC" => Some(Self::Zcash),
            "PLS" | "PULS" | "PULSEX" => Some(Self::PulseChain),
            "ZANO" => Some(Self::Zano),
            "MON" | "MONAD" => Some(Self::Monad),
            "OP" | "OPTIMISM" => Some(Self::Optimism),
            "TON" => Some(Self::Ton),
            "DOT" | "POLKADOT" => Some(Self::Polkadot),
            _ => None,
        }
    }
}

/// Block header from a foreign chain.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChainHeader {
    pub chain: ChainType,
    pub height: u64,
    pub hash: String,
    pub prev_hash: String,
    pub merkle_root: String,
    pub timestamp: u64,
    pub bits: u32,
    pub confirmations: u32,
}

/// Merkle proof for a transaction.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MerkleProof {
    pub chain: ChainType,
    pub tx_hash: String,
    pub block_height: u64,
    pub block_hash: String,
    pub merkle_path: Vec<String>,
    pub tx_index: u32,
    pub total_txs: u32,
}

/// Payment verification result.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaymentProof {
    pub chain: ChainType,
    pub tx_hash: String,
    /// Base units. `u128`, not `u64`: wei caps a `u64` at ~18.44 ETH, so any
    /// larger lock on an 18-decimal chain could not be represented and the
    /// amount check failed closed on every one of them.
    pub amount: u128,
    pub from_address: String,
    pub to_address: String,
    pub confirmations: u32,
    pub block_height: u64,
    pub block_hash: String,
    pub verified: bool,
    pub merkle_root: String,
    pub merkle_proof: Vec<String>,
    pub tx_index: u32,
    pub total_txs: u32,
}

/// Trait for SPV verification across all chains.
#[async_trait::async_trait]
pub trait ChainSpv: Send + Sync {
    fn chain_type(&self) -> ChainType;

    /// Get current block height.
    async fn get_height(&self) -> Result<u64>;

    /// Get block header by height.
    async fn get_header(&self, height: u64) -> Result<ChainHeader>;

    /// Get block header by hash.
    async fn get_header_by_hash(&self, hash: &str) -> Result<ChainHeader>;

    /// Get latest block header.
    async fn get_latest_header(&self) -> Result<ChainHeader>;

    /// Get merkle proof for a transaction.
    async fn get_merkle_proof(&self, tx_hash: &str) -> Result<MerkleProof>;

    /// Verify a merkle proof against a block header.
    fn verify_merkle(&self, proof: &MerkleProof, header: &ChainHeader) -> Result<bool>;

    /// Get payment confirmations for a transaction.
    async fn get_confirmations(&self, tx_hash: &str) -> Result<u32>;

    /// Build a full payment proof.
    async fn build_payment_proof(
        &self,
        tx_hash: &str,
        from_address: &str,
        to_address: &str,
        amount: u128,
    ) -> Result<PaymentProof>;

    /// Verify a payment proof (merkle + confirmations).
    async fn verify_payment_proof(&self, proof: &PaymentProof, min_confirmations: u32) -> Result<bool>;
}

// serde import moved to top of file
