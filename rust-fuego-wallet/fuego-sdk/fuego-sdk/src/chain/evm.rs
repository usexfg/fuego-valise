use crate::error::{Result, SdkError};
use crate::chain::evm_rpc::EvmRpcClient;
use crate::chain::{mpt, ChainSpv, ChainHeader, MerkleProof, PaymentProof, ChainType};

/// EVM adapter.
///
/// [`ChainSpv::verify_merkle`] rebuilds the block's receipt trie and checks it
/// against the header's `receiptsRoot`, so a receipt cannot be invented.
///
/// **Scope of the guarantee.** The header itself is fetched from the same RPC
/// and is not checked against a header chain, so this proves inclusion in the
/// block the RPC named, not that that block is canonical. A node that lies
/// about which block is canonical is still believed. Closing that gap needs a
/// stored header chain with a checkpoint — see the UTXO adapter's
/// `SpvHeaderStore` for the shape of it. Until then, do not describe this as
/// full SPV.
pub struct EvmChain {
    chain: ChainType,
    rpc: EvmRpcClient,
    min_confirmations: u64,
}

impl EvmChain {
    pub fn new(chain: ChainType, rpc_url: &str, min_confirmations: u64) -> Result<Self> {
        if !chain.is_evm() {
            return Err(SdkError::Config(format!(
                "EvmChain only supports EVM-compatible chains, got {chain:?}"
            )));
        }
        Ok(Self {
            chain,
            rpc: EvmRpcClient::new(rpc_url),
            min_confirmations,
        })
    }

    pub fn set_min_confirmations(&mut self, n: u64) {
        self.min_confirmations = n;
    }

    /// Every receipt in `block_hash`, RLP-encoded in index order and hex'd.
    ///
    /// Prefers `eth_getBlockReceipts`; falls back to one
    /// `eth_getTransactionReceipt` per transaction for nodes without it.
    pub async fn collect_receipts(&self, block_hash: &str) -> Result<Vec<String>> {
        let raw = match self.rpc.get_block_receipts(block_hash).await {
            Ok(v) if !v.is_empty() => v,
            _ => {
                let hashes = self.rpc.get_block_tx_hashes(block_hash).await?;
                let mut out = Vec::with_capacity(hashes.len());
                for h in hashes {
                    out.push(self.rpc.get_receipt_json(&h).await?);
                }
                out
            }
        };
        raw.iter()
            .map(|r| consensus_receipt_from_json(r).map(|c| hex::encode(c.encode())))
            .collect()
    }
}

/// Build the consensus form of a receipt from an `eth_getTransactionReceipt`
/// JSON object.
///
/// Every field is required. A missing one cannot be defaulted: a receipt
/// assembled from guesses hashes to something, and that something would be
/// compared against a real root as if it meant anything.
fn consensus_receipt_from_json(r: &serde_json::Value) -> Result<mpt::ConsensusReceipt> {
    fn hex_u64(v: Option<&str>, what: &str) -> Result<u64> {
        v.and_then(|s| u64::from_str_radix(s.trim_start_matches("0x"), 16).ok())
            .ok_or_else(|| SdkError::Network(format!("receipt missing {what}")))
    }
    fn hex_vec(v: Option<&str>, what: &str) -> Result<Vec<u8>> {
        let s = v.ok_or_else(|| SdkError::Network(format!("receipt missing {what}")))?;
        hex::decode(s.trim_start_matches("0x"))
            .map_err(|e| SdkError::Serialization(format!("{what}: {e}")))
    }

    // `type` is absent on pre-EIP-2718 nodes, which means a legacy receipt.
    let tx_type = match r.get("type").and_then(|t| t.as_str()) {
        Some(t) => u8::from_str_radix(t.trim_start_matches("0x"), 16)
            .map_err(|e| SdkError::Serialization(format!("receipt type: {e}")))?,
        None => 0,
    };
    let status = hex_u64(r.get("status").and_then(|v| v.as_str()), "status")? as u8;
    let cumulative_gas_used = hex_u64(
        r.get("cumulativeGasUsed").and_then(|v| v.as_str()),
        "cumulativeGasUsed",
    )?;
    let logs_bloom = hex_vec(r.get("logsBloom").and_then(|v| v.as_str()), "logsBloom")?;
    if logs_bloom.len() != 256 {
        return Err(SdkError::Network(format!(
            "logsBloom is {} bytes, expected 256",
            logs_bloom.len()
        )));
    }

    let logs_json = r
        .get("logs")
        .and_then(|l| l.as_array())
        .ok_or_else(|| SdkError::Network("receipt missing logs".into()))?;
    let mut logs = Vec::with_capacity(logs_json.len());
    for l in logs_json {
        let address = hex_vec(l.get("address").and_then(|v| v.as_str()), "log address")?;
        let topics_json = l
            .get("topics")
            .and_then(|t| t.as_array())
            .ok_or_else(|| SdkError::Network("log missing topics".into()))?;
        let mut topics = Vec::with_capacity(topics_json.len());
        for t in topics_json {
            topics.push(hex_vec(t.as_str(), "log topic")?);
        }
        let data = hex_vec(l.get("data").and_then(|v| v.as_str()), "log data")?;
        logs.push((address, topics, data));
    }

    Ok(mpt::ConsensusReceipt {
        tx_type,
        status,
        cumulative_gas_used,
        logs_bloom,
        logs,
    })
}

#[async_trait::async_trait]
impl ChainSpv for EvmChain {
    fn chain_type(&self) -> ChainType {
        self.chain
    }

    async fn get_height(&self) -> Result<u64> {
        self.rpc.get_block_number().await
    }

    async fn get_header(&self, height: u64) -> Result<ChainHeader> {
        let block = self.rpc.get_block_by_number(height).await?;
        Ok(ChainHeader {
            chain: self.chain,
            height,
            hash: block.hash,
            prev_hash: block.parent_hash,
            merkle_root: block.receipts_root, // EVM uses receiptsRoot for receipt verification
            timestamp: block.timestamp,
            bits: 0,
            confirmations: 0,
        })
    }

    async fn get_header_by_hash(&self, hash: &str) -> Result<ChainHeader> {
        let block = self.rpc.get_block_by_hash(hash).await?;
        Ok(ChainHeader {
            chain: self.chain,
            height: block.number,
            hash: block.hash,
            prev_hash: block.parent_hash,
            merkle_root: block.receipts_root,
            timestamp: block.timestamp,
            bits: 0,
            confirmations: 0,
        })
    }

    async fn get_latest_header(&self) -> Result<ChainHeader> {
        let height = self.get_height().await?;
        self.get_header(height).await
    }

    /// Collects the block's receipts into `merkle_path` so [`Self::verify_merkle`]
    /// can rebuild the trie. The old version put the transaction index in
    /// there as a decimal string, which proved nothing.
    async fn get_merkle_proof(&self, tx_hash: &str) -> Result<MerkleProof> {
        let receipt = self.rpc.get_transaction_receipt(tx_hash).await?;
        let encoded = self.collect_receipts(&receipt.block_hash).await?;
        Ok(MerkleProof {
            chain: self.chain,
            tx_hash: tx_hash.to_string(),
            block_height: receipt.block_number,
            block_hash: receipt.block_hash,
            total_txs: encoded.len() as u32,
            merkle_path: encoded,
            tx_index: receipt.transaction_index as u32,
        })
    }

    /// Receipt-trie inclusion.
    ///
    /// `proof.merkle_path` carries the block's receipts, RLP-encoded, in index
    /// order (see [`EvmChain::collect_receipts`]). Rebuilding the trie and
    /// comparing its root to the header's `receiptsRoot` proves the receipt at
    /// `tx_index` is in the block that header commits to.
    ///
    /// What this does NOT prove: that the header is canonical. That needs a
    /// verified header chain, which this adapter does not keep — see the note
    /// on [`EvmChain`].
    fn verify_merkle(&self, proof: &MerkleProof, header: &ChainHeader) -> Result<bool> {
        if proof.block_hash != header.hash || proof.block_height == 0 {
            return Ok(false);
        }
        if proof.merkle_path.is_empty() {
            // No receipts collected — cannot claim inclusion.
            return Ok(false);
        }
        if proof.tx_index as usize >= proof.merkle_path.len() {
            return Ok(false);
        }
        let mut entries: Vec<(Vec<u8>, Vec<u8>)> = Vec::with_capacity(proof.merkle_path.len());
        for (i, encoded_hex) in proof.merkle_path.iter().enumerate() {
            let encoded = hex::decode(encoded_hex.trim_start_matches("0x"))
                .map_err(|e| SdkError::Serialization(format!("receipt {i} hex: {e}")))?;
            entries.push((mpt::rlp_uint(i as u64), encoded));
        }
        let root = mpt::trie_root(entries).map_err(SdkError::Serialization)?;
        let expected = hex::decode(header.merkle_root.trim_start_matches("0x"))
            .map_err(|e| SdkError::Serialization(format!("receiptsRoot hex: {e}")))?;
        Ok(root.as_slice() == expected.as_slice())
    }

    async fn get_confirmations(&self, tx_hash: &str) -> Result<u32> {
        let receipt = self.rpc.get_transaction_receipt(tx_hash).await?;
        let current_height = self.get_height().await?;

        if current_height >= receipt.block_number {
            Ok((current_height - receipt.block_number + 1) as u32)
        } else {
            // Stale data or reorg
            Ok(0)
        }
    }

    async fn build_payment_proof(
        &self,
        tx_hash: &str,
        from_address: &str,
        to_address: &str,
        amount: u128,
    ) -> Result<PaymentProof> {
        let merkle = self.get_merkle_proof(tx_hash).await?;
        let header = self.get_header(merkle.block_height).await?;
        let confirmations = self.get_confirmations(tx_hash).await?;

        Ok(PaymentProof {
            chain: self.chain,
            tx_hash: tx_hash.to_string(),
            amount,
            from_address: from_address.to_string(),
            to_address: to_address.to_string(),
            confirmations,
            block_height: merkle.block_height,
            block_hash: merkle.block_hash.clone(),
            verified: false,
            merkle_root: header.merkle_root.clone(),
            merkle_proof: merkle.merkle_path,
            tx_index: merkle.tx_index,
            total_txs: merkle.total_txs,
        })
    }

    async fn verify_payment_proof(&self, proof: &PaymentProof, min_confirmations: u32) -> Result<bool> {
        if proof.confirmations < min_confirmations {
            return Ok(false);
        }

        let header = self.get_header(proof.block_height).await?;

        // Verify block hash matches and merkle root matches
        if proof.block_hash != header.hash {
            return Ok(false);
        }
        if proof.merkle_root != header.merkle_root {
            return Ok(false);
        }

        // Receipt-trie inclusion. This is the step that makes the rest mean
        // something: without it the checks below only say "the RPC told me so
        // twice". verify_merkle was implemented but never called from here.
        let merkle = MerkleProof {
            chain: self.chain,
            tx_hash: proof.tx_hash.clone(),
            block_height: proof.block_height,
            block_hash: proof.block_hash.clone(),
            merkle_path: proof.merkle_proof.clone(),
            tx_index: proof.tx_index,
            total_txs: proof.total_txs,
        };
        if !self.verify_merkle(&merkle, &header)? {
            return Ok(false);
        }

        // Verify the receipt exists in the claimed block and succeeded.
        let receipt = self.rpc.get_transaction_receipt(&proof.tx_hash).await?;
        if receipt.block_hash != proof.block_hash {
            return Ok(false);
        }
        if receipt.block_number != proof.block_height {
            return Ok(false);
        }
        // Reverted transactions must never verify.
        if receipt.status != "0x1" {
            return Ok(false);
        }
        // The receipt must sit at the index the proof claims, or the trie
        // inclusion above proves something about a different transaction.
        if receipt.transaction_index != proof.tx_index as u64 {
            return Ok(false);
        }

        // Verify the on-chain amount + sender + recipient (iron law:
        // verifyLock checks amount and recipient). Addresses are compared
        // case-insensitively; RPCs vary in checksum casing.
        let tx = self.rpc.get_transaction_by_hash(&proof.tx_hash).await?;
        if tx.block_number != Some(proof.block_height) {
            return Ok(false);
        }
        if !tx.to.eq_ignore_ascii_case(&proof.to_address) {
            return Ok(false);
        }
        if !proof.from_address.is_empty() && !tx.from.eq_ignore_ascii_case(&proof.from_address) {
            return Ok(false);
        }
        // u128: a u64 parse returned None for anything above ~18.44 ETH, so
        // every larger lock failed the amount check regardless of its value.
        let value_wei = crate::chain::evm_rpc::parse_hex_u128_public(&tx.value);
        if value_wei != Some(proof.amount) {
            return Ok(false);
        }

        // Wrong-network RPC detection: the chain id must match this
        // ChainType's. The table lives on ChainType now — the local copy here
        // returned 0 for every chain past Polygon, so those either compared
        // against 0 or were unreachable.
        let expected = self
            .chain
            .evm_chain_id()
            .ok_or_else(|| SdkError::Config(format!("{:?} has no EVM chain id", self.chain)))?;
        let chain_id = self.rpc.get_chain_id().await?;
        if chain_id != expected {
            return Ok(false);
        }

        Ok(true)
    }
}

// ── Receipt / Transaction types ────────────────────────────────────

#[derive(Debug, Clone)]
pub struct EvmReceipt {
    pub block_hash: String,
    pub block_number: u64,
    pub transaction_index: u64,
    pub status: String,
    pub logs_bloom: String,
}

#[derive(Debug, Clone)]
pub struct EvmBlock {
    pub hash: String,
    pub parent_hash: String,
    pub number: u64,
    pub timestamp: u64,
    pub logs_bloom: String,
    pub receipts_root: String,
}

#[derive(Debug, Clone)]
pub struct EvmTx {
    pub hash: String,
    pub from: String,
    pub to: String,
    pub value: String,
    pub block_number: Option<u64>,
}
