//! # Fuego SDK
//!
//! Modular SDK for the Fuego blockchain. Provides an embedded node with pluggable
//! networking, storage, wallet, and platform adapters.
//!
//! ## Architecture
//!
//! ```text
//! ┌─────────────────────────────────────────────────────────────┐
//! │                      Application Layer                       │
//! │  (Flutter, Native, Web, CLI, etc.)                          │
//! └─────────────────────────────────────────────────────────────┘
//!                              │
//! ┌─────────────────────────────────────────────────────────────┐
//! │                     Platform Adapters                        │
//! │  (FFI, HTTP, WebSocket, etc.)                               │
//! └─────────────────────────────────────────────────────────────┘
//!                              │
//! ┌─────────────────────────────────────────────────────────────┐
//! │                        Fuego SDK                            │
//! │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
//! │  │  Wallet   │  │   Node   │  │  Store   │  │  Crypto  │   │
//! │  │ (Vault,   │  │  (Sync,  │  │ (Memory, │  │  (Keys,  │   │
//! │  │ Scanner)  │  │  RPC)    │  │  Sled)   │  │  Signs)  │   │
//! │  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
//! └─────────────────────────────────────────────────────────────┘
//!                              │
//! ┌─────────────────────────────────────────────────────────────┐
//! │                    Network Providers                         │
//! │  (P2P, I2P, RPC, Mock, etc.)                                │
//! └─────────────────────────────────────────────────────────────┘
//! ```

pub mod builder;
pub mod crypto;
pub mod error;
pub mod network;
pub mod node;
pub mod scanner;
pub mod serialization;
pub mod store;
pub mod suite;
pub mod traits;
pub mod transaction_builder;
pub mod types;
pub mod vault;
pub mod wallet;
pub mod alias;
pub mod orderbook;
pub mod cd_market;
pub mod chain;

pub use builder::{SdkBuilder, WalletBuilder};
pub use error::{Result, SdkError};
pub use network::{NullNetwork, RpcProvider};
pub use node::EmbeddedNode;
pub use scanner::UtxoScanner;
pub use store::MemoryStore;
pub use traits::*;
pub use types::*;
pub use vault::WalletVault;
pub use wallet::Wallet;
pub use orderbook::OrderbookClient;
pub use cd_market::CdMarketClient;
pub use chain::{ChainType, ChainHeader, MerkleProof, PaymentProof, BitcoinChain, EvmChain};
pub use types::SwapPair;
