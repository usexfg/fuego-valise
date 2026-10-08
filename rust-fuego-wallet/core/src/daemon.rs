use reqwest::Client;
use serde::{Deserialize, Serialize};

#[derive(Clone)]
pub struct DaemonClient {
    pub base_url: String,
    client: Client,
}

#[derive(Debug, Deserialize)]
pub struct DaemonInfo {
    pub height: u64,
    pub difficulty: u64,
    pub tx_count: u64,
    pub tx_pool_size: u64,
    pub incoming_connections_count: u64,
    pub outgoing_connections_count: u64,
    pub last_block_timestamp: u64,
    pub last_block_reward: u64,
    pub top_block_hash: String,
    #[serde(default)]
    pub fee_address: String,
    pub status: String,
    pub version: String,
}

/// The Hearth pool as /amm_pool_info reports it.
#[derive(Debug, Clone, Copy, Default)]
pub struct PoolInfo {
    pub reserve_xfg: u64,
    pub reserve_heat: u64,
    pub total_lp_shares: u64,
    /// HEAT atomics per XFG atomic × COIN.
    pub spot_price: u64,
    /// The 8-block TWAP consensus prices HEAT mints at (0 = none yet).
    pub hearth_twap: u64,
    pub height: u64,
}

/// What a CD has accrued (COMMAND_RPC_ESTIMATE_CD_YIELD).
#[derive(Debug, Clone, Copy, Default)]
pub struct CdClaimInfo {
    pub formula_interest: u64,
    pub base_interest: u64,
    pub bonus_interest: u64,
    pub claimable_bonus: u64,
    pub fee_pool_balance: u64,
    pub vault_balance: u64,
    pub bonus_vault_balance: u64,
    pub pool_info_present: bool,
}

/// A Hearth limit order (COMMAND_RPC_GET_LIMIT_ORDERS::LimitOrderInfo).
#[derive(Debug, Clone, Default)]
pub struct LimitOrder {
    pub order_id: String,
    pub address_hash: String,
    pub side: u8,
    /// Remaining escrow.
    pub amount: u64,
    pub proceeds_xfg: u64,
    pub proceeds_heat: u64,
    pub target_price: u64,
    pub expiration: u32,
    pub withdrawn: bool,
}

#[derive(Debug, Serialize)]
struct JsonRpcRequest {
    jsonrpc: String,
    id: String,
    method: String,
    params: serde_json::Value,
}

#[derive(Debug, Deserialize)]
struct JsonRpcResponse<T> {
    result: Option<T>,
    error: Option<JsonRpcError>,
}

#[derive(Debug, Deserialize)]
struct JsonRpcError {
    message: String,
}

impl DaemonClient {
    pub fn new(base_url: &str) -> Self {
        let client = Client::builder()
            .timeout(std::time::Duration::from_secs(60))
            .build()
            .expect("build reqwest client");
        Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            client,
        }
    }

    pub async fn get_info(&self) -> Result<DaemonInfo, String> {
        let url = format!("{}/getinfo", self.base_url);
        let resp = self.client.get(&url).send().await
            .map_err(|e| format!("HTTP: {}", e))?;
        resp.json::<DaemonInfo>().await
            .map_err(|e| format!("JSON: {}", e))
    }

    pub async fn get_height(&self) -> Result<u64, String> {
        let resp = self.json_rpc::<serde_json::Value>("getblockcount", serde_json::json!({})).await?;
        resp.get("count").and_then(|v| v.as_u64())
            .ok_or("missing count".into())
    }

    pub async fn get_block_hash(&self, height: u64) -> Result<String, String> {
        self.json_rpc::<String>("on_getblockhash", serde_json::json!([height])).await
    }

    pub async fn send_raw_tx(&self, tx_hex: &str) -> Result<String, String> {
        let url = format!("{}/sendrawtransaction", self.base_url);
        let resp = self.client.post(&url)
            .json(&serde_json::json!({"tx_as_hex": tx_hex}))
            .send().await.map_err(|e| format!("HTTP: {}", e))?;
        let val: serde_json::Value = resp.json().await
            .map_err(|e| format!("JSON: {}", e))?;
        val["status"].as_str().map(|s| s.to_string())
            .ok_or("missing status".into())
    }

    /// Binary POST helper for the .bin endpoints.
    async fn post_bin(&self, path: &str, body: Vec<u8>) -> Result<Vec<u8>, String> {
        let url = format!("{}{}", self.base_url, path);
        let resp = self.client.post(&url)
            .header("Content-Type", "application/octet-stream")
            .body(body)
            .send().await
            .map_err(|e| format!("HTTP: {}", e))?;
        if !resp.status().is_success() {
            return Err(format!("HTTP {} from {}", resp.status(), path));
        }
        resp.bytes().await.map(|b| b.to_vec()).map_err(|e| format!("body: {}", e))
    }

    /// /queryblockslite.bin — incremental block + tx-prefix sync.
    pub async fn query_blocks_lite(
        &self,
        block_ids: &[[u8; 32]],
        timestamp: u64,
    ) -> Result<fuego_sdk::serialization::QueryBlocksLiteResponse, String> {
        use fuego_sdk::serialization::{parse_query_blocks_lite_response, query_blocks_lite_request};
        let body = query_blocks_lite_request(block_ids, timestamp);
        let resp = self.post_bin("/queryblockslite.bin", body).await?;
        parse_query_blocks_lite_response(&resp).map_err(|e| e.to_string())
    }

    /// /getrandom_outs.bin — decoy outputs for the given amounts.
    pub async fn get_random_outs(
        &self,
        amounts: &[u64],
        outs_count: u64,
    ) -> Result<Vec<fuego_sdk::serialization::RandomOutsForAmount>, String> {
        use fuego_sdk::serialization::{get_random_outs_request, parse_get_random_outs_response};
        let body = get_random_outs_request(amounts, outs_count);
        let resp = self.post_bin("/getrandom_outs.bin", body).await?;
        parse_get_random_outs_response(&resp).map_err(|e| e.to_string())
    }

    /// /get_o_indexes.bin — global output indices of a transaction, aligned
    /// with its outputs. Request: KV doc {txid: 32-byte hash}. Response:
    /// KV doc {o_indexes: array<uint64>, status: string}.
    pub async fn get_o_indexes(&self, tx_hash: &[u8; 32]) -> Result<Vec<u64>, String> {
        use fuego_sdk::serialization::{
            get_o_indexes_request, parse_get_o_indexes_response,
        };
        let body = get_o_indexes_request(tx_hash);
        let resp = self.post_bin("/get_o_indexes.bin", body).await?;
        parse_get_o_indexes_response(&resp).map_err(|e| e.to_string())
    }

    /// /getrandom_commitment_outs.bin — decoy commitment outputs for one
    /// amount. With `term` the node returns only outputs that can share that
    /// output's ring: the same asset, spendable now (0 = any).
    pub async fn get_random_commitment_outs(
        &self,
        amount: u64,
        outs_count: u64,
        max_height: u32,
        term: u32,
    ) -> Result<Vec<fuego_sdk::serialization::RandomCommitmentOutEntry>, String> {
        use fuego_sdk::serialization::{
            get_random_commitment_outs_request, parse_get_random_commitment_outs_response,
        };
        let body = get_random_commitment_outs_request(amount, outs_count, max_height, term);
        let resp = self.post_bin("/getrandom_commitment_outs.bin", body).await?;
        parse_get_random_commitment_outs_response(&resp).map_err(|e| e.to_string())
    }

    /// /amm_pool_info — the Hearth pool. fuegod serves it at its own path; it
    /// is not a /json_rpc method.
    pub async fn amm_pool(&self) -> Result<PoolInfo, String> {
        let val = self.json_path("/amm_pool_info", serde_json::json!({})).await?;
        let get = |k: &str| val.get(k).and_then(|v| v.as_u64()).unwrap_or(0);
        Ok(PoolInfo {
            reserve_xfg: get("reserve_xfg"),
            reserve_heat: get("reserve_heat"),
            total_lp_shares: get("total_lp_shares"),
            spot_price: get("spot_price"),
            hearth_twap: get("hearth_twap"),
            height: get("height"),
        })
    }

    /// /estimate_cd_yield — what a CD has accrued and what consensus would
    /// pay out of it now (NodeRpcProxy::getCdClaimInfo).
    pub async fn cd_claim_info(
        &self,
        amount: u64,
        creation_height: u32,
        current_height: u32,
        term: u32,
    ) -> Result<CdClaimInfo, String> {
        let val = self
            .json_path(
                "/estimate_cd_yield",
                serde_json::json!({
                    "amount": amount,
                    "creation_height": creation_height,
                    "current_height": current_height,
                    "term": term,
                }),
            )
            .await?;
        let get = |k: &str| val.get(k).and_then(|v| v.as_u64()).unwrap_or(0);
        if val.get("estimated_interest").and_then(|v| v.as_u64()).is_none() {
            return Err(format!("bad estimate_cd_yield response: {}", val));
        }
        Ok(CdClaimInfo {
            formula_interest: get("estimated_interest"),
            base_interest: get("base_interest"),
            bonus_interest: get("bonus_interest"),
            claimable_bonus: get("claimable_bonus"),
            fee_pool_balance: get("fee_pool_balance"),
            vault_balance: get("cd_apy_vault_balance"),
            bonus_vault_balance: get("bonus_vault_balance"),
            pool_info_present: val.get("pool_info_present").and_then(|v| v.as_bool()).unwrap_or(false),
        })
    }

    /// /estimate_cd_yield — the interest a CD would pay today.
    pub async fn estimate_cd_yield(
        &self,
        amount: u64,
        creation_height: u32,
    ) -> Result<u64, String> {
        self.cd_claim_info(amount, creation_height, 0, 0)
            .await
            .map(|info| info.formula_interest)
    }

    /// /get_limit_orders — Hearth limit orders, withdrawn ones included.
    pub async fn limit_orders(&self) -> Result<Vec<LimitOrder>, String> {
        let val = self
            .json_path(
                "/get_limit_orders",
                serde_json::json!({ "active_only": false, "limit": 0, "offset": 0 }),
            )
            .await?;
        let orders = val
            .get("orders")
            .and_then(|o| o.as_array())
            .ok_or_else(|| format!("bad get_limit_orders response: {}", val))?;
        let mut out = Vec::with_capacity(orders.len());
        for o in orders {
            let get = |k: &str| o.get(k).and_then(|v| v.as_u64()).unwrap_or(0);
            let text = |k: &str| o.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
            out.push(LimitOrder {
                order_id: text("order_id"),
                address_hash: text("address_hash"),
                side: get("side") as u8,
                amount: get("amount"),
                proceeds_xfg: get("proceeds_xfg"),
                proceeds_heat: get("proceeds_heat"),
                target_price: get("target_price"),
                expiration: get("expiration") as u32,
                withdrawn: o.get("withdrawn").and_then(|v| v.as_bool()).unwrap_or(false),
            });
        }
        Ok(out)
    }

    /// /is_key_image_spent. Returns an error if the daemon does not provide
    /// the endpoint (older builds); callers fall back to scan-based spent
    /// tracking.
    pub async fn is_key_image_spent(&self, key_image: &[u8; 32]) -> Result<bool, String> {
        let val = self
            .json_path(
                "/is_key_image_spent",
                serde_json::json!({ "key_image": hex::encode(key_image) }),
            )
            .await?;
        val.get("spent")
            .and_then(|v| v.as_bool())
            .ok_or_else(|| format!("bad is_key_image_spent response: {}", val))
    }

    /// POST a JSON body to one of fuegod's own paths (jsonMethod handlers).
    async fn json_path(&self, path: &str, body: serde_json::Value) -> Result<serde_json::Value, String> {
        let url = format!("{}{}", self.base_url, path);
        let resp = self.client.post(&url)
            .json(&body).send().await
            .map_err(|e| format!("HTTP: {}", e))?;
        if !resp.status().is_success() {
            return Err(format!("HTTP {} from {}", resp.status(), path));
        }
        resp.json().await.map_err(|e| format!("JSON from {}: {}", path, e))
    }

    async fn json_rpc<T: serde::de::DeserializeOwned>(
        &self, method: &str, params: serde_json::Value,
    ) -> Result<T, String> {
        let url = format!("{}/json_rpc", self.base_url);
        let req = JsonRpcRequest {
            jsonrpc: "2.0".into(),
            id: "1".into(),
            method: method.into(),
            params,
        };
        let resp: JsonRpcResponse<T> = self.client.post(&url)
            .json(&req).send().await
            .map_err(|e| format!("HTTP: {}", e))?
            .json().await
            .map_err(|e| format!("JSON: {}", e))?;
        if let Some(err) = resp.error {
            Err(format!("RPC: {}", err.message))
        } else {
            resp.result.ok_or("no result".into())
        }
    }
}
