use crate::error::{Result, SdkError};
use crate::chain::evm::{EvmReceipt, EvmBlock, EvmTx};
use reqwest::Client;

/// JSON-RPC client for EVM-compatible chains (ETH, ARB, BASE).
pub struct EvmRpcClient {
    url: String,
    client: Client,
}

impl EvmRpcClient {
    pub fn new(url: impl Into<String>) -> Self {
        Self {
            url: url.into(),
            client: Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .build()
                .unwrap_or_else(|_| Client::new()),
        }
    }

    pub async fn get_block_number(&self) -> Result<u64> {
        let hex: String = self.eth_call("eth_blockNumber", &[]).await?;
        parse_hex_u64(&hex).ok_or_else(|| SdkError::Network(format!("Invalid block number: {hex}")))
    }

    pub async fn get_block_by_number(&self, number: u64) -> Result<EvmBlock> {
        let block: serde_json::Value = self.eth_call("eth_getBlockByNumber", &[
            serde_json::json!(format!("0x{:x}", number)),
            serde_json::json!(false),
        ]).await?;

        Ok(EvmBlock {
            hash: block["hash"].as_str().unwrap_or("0x0").to_string(),
            parent_hash: block["parentHash"].as_str().unwrap_or("0x0").to_string(),
            number: parse_hex_u64(block["number"].as_str().unwrap_or("0x0")).unwrap_or(0),
            timestamp: parse_hex_u64(block["timestamp"].as_str().unwrap_or("0x0")).unwrap_or(0),
            logs_bloom: block["logsBloom"].as_str().unwrap_or("0x0").to_string(),
            receipts_root: block["receiptsRoot"].as_str().unwrap_or("0x0").to_string(),
        })
    }

    pub async fn get_block_by_hash(&self, hash: &str) -> Result<EvmBlock> {
        let block: serde_json::Value = self.eth_call("eth_getBlockByHash", &[
            serde_json::json!(hash),
            serde_json::json!(false),
        ]).await?;

        Ok(EvmBlock {
            hash: block["hash"].as_str().unwrap_or("0x0").to_string(),
            parent_hash: block["parentHash"].as_str().unwrap_or("0x0").to_string(),
            number: parse_hex_u64(block["number"].as_str().unwrap_or("0x0")).unwrap_or(0),
            timestamp: parse_hex_u64(block["timestamp"].as_str().unwrap_or("0x0")).unwrap_or(0),
            logs_bloom: block["logsBloom"].as_str().unwrap_or("0x0").to_string(),
            receipts_root: block["receiptsRoot"].as_str().unwrap_or("0x0").to_string(),
        })
    }

    pub async fn get_transaction_receipt(&self, tx_hash: &str) -> Result<EvmReceipt> {
        let receipt: serde_json::Value = self.eth_call("eth_getTransactionReceipt", &[
            serde_json::json!(tx_hash),
        ]).await?;

        if receipt.is_null() {
            return Err(SdkError::Network(format!("Transaction {tx_hash} not found")));
        }

        // Fail closed: a missing status field must not be treated as success.
        let status = receipt["status"]
            .as_str()
            .ok_or_else(|| SdkError::Network(format!("Receipt for {tx_hash} missing status")))?
            .to_string();
        if status != "0x1" && status != "0x0" {
            return Err(SdkError::Network(format!(
                "Unexpected receipt status for {tx_hash}: {status}"
            )));
        }

        let tx_index = parse_hex_u64(receipt["transactionIndex"].as_str().unwrap_or("0x0"))
            .ok_or_else(|| SdkError::Network(format!("Invalid transactionIndex for {tx_hash}")))?;

        Ok(EvmReceipt {
            block_hash: receipt["blockHash"].as_str().unwrap_or("0x0").to_string(),
            block_number: parse_hex_u64(receipt["blockNumber"].as_str().unwrap_or("0x0")).unwrap_or(0),
            transaction_index: tx_index,
            status,
            logs_bloom: receipt["logsBloom"].as_str().unwrap_or("0x0").to_string(),
        })
    }

    pub async fn get_transaction_by_hash(&self, tx_hash: &str) -> Result<EvmTx> {
        let tx: serde_json::Value = self.eth_call("eth_getTransactionByHash", &[
            serde_json::json!(tx_hash),
        ]).await?;

        if tx.is_null() {
            return Err(SdkError::Network(format!("Transaction {tx_hash} not found")));
        }

        Ok(EvmTx {
            hash: tx["hash"].as_str().unwrap_or("0x0").to_string(),
            from: tx["from"].as_str().unwrap_or("0x0").to_string(),
            to: tx["to"].as_str().unwrap_or("0x0").to_string(),
            value: tx["value"].as_str().unwrap_or("0x0").to_string(),
            block_number: tx["blockNumber"].as_str().and_then(parse_hex_u64),
        })
    }

    /// Get balance in wei. Returns u128 to handle large balances (ETH is 256-bit).
    pub async fn get_balance(&self, address: &str) -> Result<u128> {
        let hex: String = self.eth_call("eth_getBalance", &[
            serde_json::json!(address),
            serde_json::json!("latest"),
        ]).await?;
        parse_hex_u128(&hex).ok_or_else(|| SdkError::Network(format!("Invalid balance: {hex}")))
    }

    /// All receipts in a block, as raw JSON, in index order.
    ///
    /// `eth_getBlockReceipts` is the one call that makes a real receipt-trie
    /// check possible: rebuilding the trie needs every receipt, not just ours.
    /// Falls back to per-transaction fetches on nodes that do not serve it.
    pub async fn get_block_receipts(&self, block_hash: &str) -> Result<Vec<serde_json::Value>> {
        let v: serde_json::Value = self
            .eth_call("eth_getBlockReceipts", &[serde_json::json!(block_hash)])
            .await?;
        let arr = v
            .as_array()
            .ok_or_else(|| SdkError::Network("eth_getBlockReceipts did not return a list".into()))?;
        Ok(arr.clone())
    }

    /// Transaction hashes of a block, in index order.
    pub async fn get_block_tx_hashes(&self, block_hash: &str) -> Result<Vec<String>> {
        let block: serde_json::Value = self
            .eth_call(
                "eth_getBlockByHash",
                &[serde_json::json!(block_hash), serde_json::json!(false)],
            )
            .await?;
        let txs = block["transactions"]
            .as_array()
            .ok_or_else(|| SdkError::Network("block has no transactions list".into()))?;
        Ok(txs
            .iter()
            .filter_map(|t| t.as_str().map(|s| s.to_string()))
            .collect())
    }

    /// One receipt as raw JSON.
    pub async fn get_receipt_json(&self, tx_hash: &str) -> Result<serde_json::Value> {
        let v: serde_json::Value = self
            .eth_call("eth_getTransactionReceipt", &[serde_json::json!(tx_hash)])
            .await?;
        if v.is_null() {
            return Err(SdkError::Network(format!("receipt {tx_hash} not found")));
        }
        Ok(v)
    }

    pub async fn get_chain_id(&self) -> Result<u64> {
        let hex: String = self.eth_call("eth_chainId", &[]).await?;
        parse_hex_u64(&hex).ok_or_else(|| SdkError::Network(format!("Invalid chain ID: {hex}")))
    }

    // ── ERC20 helpers (raw eth_call) ─────────────────────────────────

    /// Raw eth_call to an ERC20 contract. `data` must be 0x-prefixed hex.
    pub async fn erc20_call(&self, token: &str, data_hex: &str) -> Result<String> {
        let hex: String = self.eth_call("eth_call", &[
            serde_json::json!({"to": token, "data": data_hex}),
            serde_json::json!("latest"),
        ]).await?;
        Ok(hex)
    }

    pub async fn get_erc20_balance(&self, token: &str, holder: &str) -> Result<u128> {
        let holder_clean = holder.trim_start_matches("0x").to_lowercase();
        let padded = format!("{:0>64}", holder_clean);
        let data = format!("0x70a08231{}", padded);
        let hex = self.erc20_call(token, &data).await?;
        parse_hex_u128(&hex).ok_or_else(|| SdkError::Network(format!("Invalid ERC20 balance: {hex}")))
    }

    pub async fn get_erc20_decimals(&self, token: &str) -> Result<u8> {
        let hex = self.erc20_call(token, "0x313ce567").await?;
        let v = parse_hex_u64(&hex).ok_or_else(|| SdkError::Network(format!("Invalid decimals: {hex}")))?;
        Ok(v as u8)
    }

    pub async fn get_erc20_allowance(&self, token: &str, owner: &str, spender: &str) -> Result<u128> {
        let o = format!("{:0>64}", owner.trim_start_matches("0x").to_lowercase());
        let s = format!("{:0>64}", spender.trim_start_matches("0x").to_lowercase());
        let data = format!("0xdd62ed3e{}{}", o, s);
        let hex = self.erc20_call(token, &data).await?;
        parse_hex_u128(&hex).ok_or_else(|| SdkError::Network(format!("Invalid allowance: {hex}")))
    }

    pub fn erc20_transfer_data(to: &str, amount: u128) -> String {
        let addr = format!("{:0>64}", to.trim_start_matches("0x").to_lowercase());
        let amt = format!("{:0>64x}", amount);
        format!("0xa9059cbb{}{}", addr, amt)
    }

    pub fn erc20_approve_data(spender: &str, amount: u128) -> String {
        let addr = format!("{:0>64}", spender.trim_start_matches("0x").to_lowercase());
        let amt = format!("{:0>64x}", amount);
        format!("0x095ea7b3{}{}", addr, amt)
    }

    async fn eth_call<T: serde::de::DeserializeOwned>(&self, method: &str, params: &[serde_json::Value]) -> Result<T> {
        let body = serde_json::json!({
            "jsonrpc": "2.0",
            "id": "fuego-sdk",
            "method": method,
            "params": params,
        });

        let resp = self.client
            .post(&self.url)
            .json(&body)
            .send()
            .await
            .map_err(|e| SdkError::Network(format!("EVM RPC call {method} failed: {e}")))?;

        let status = resp.status();
        let text = resp.text().await
            .map_err(|e| SdkError::Network(format!("Failed to read EVM response: {e}")))?;

        if !status.is_success() {
            return Err(SdkError::Network(format!("EVM {method} returned {status}")));
        }

        let json: serde_json::Value = serde_json::from_str(&text)
            .map_err(|e| SdkError::Serialization(format!("Invalid EVM response: {e}")))?;

        if let Some(err) = json.get("error").filter(|e| !e.is_null()) {
            return Err(SdkError::Network(format!("EVM error in {method}: {err}")));
        }

        serde_json::from_value(json["result"].clone())
            .map_err(|e| SdkError::Serialization(format!("Failed to decode EVM result of {method}: {e}")))
    }
}

fn parse_hex_u64(hex_str: &str) -> Option<u64> {
    let clean = hex_str.trim_start_matches("0x");
    u64::from_str_radix(clean, 16).ok()
}

/// Public wrapper for `parse_hex_u64`.
pub fn parse_hex_u64_public(hex_str: &str) -> Option<u64> {
    parse_hex_u64(hex_str)
}

/// Public `u128` parse — used by the EVM adapter to compare the on-chain tx
/// value in wei against the proof amount. Wei does not fit a `u64` above
/// ~18.44 ETH.
pub fn parse_hex_u128_public(hex_str: &str) -> Option<u128> {
    parse_hex_u128(hex_str)
}

fn parse_hex_u128(hex_str: &str) -> Option<u128> {
    let clean = hex_str.trim_start_matches("0x");
    u128::from_str_radix(clean, 16).ok()
}
