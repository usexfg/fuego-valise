use fuego_sdk::suite::fuegod::{
    AmmPoolInfoRequest, AmmPoolInfoResponse, EstimateCdYieldRequest, EstimateCdYieldResponse,
    GetAliasRequest, GetAliasResponse, IsKeyImageSpentRequest, IsKeyImageSpentResponse,
    SendRawTxRequest, SendRawTxResponse,
};
use reqwest::Client;
use serde::{de::DeserializeOwned, Deserialize, Serialize};

/// fuegod client. Every call uses the transport fuegod registers for it
/// (RpcServer.cpp): HTTP JSON endpoints, KV-binary `.bin` endpoints, or
/// `/json_rpc` methods — see `fuego_sdk::suite::rpc`.
#[derive(Clone)]
pub struct DaemonClient {
    pub base_url: String,
    client: Client,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
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
    pub fee_address: String,
    pub status: String,
    pub version: String,
}

#[derive(Debug, Serialize)]
struct JsonRpcRequest<'a> {
    jsonrpc: &'a str,
    id: &'a str,
    method: &'a str,
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

fn require_ok(endpoint: &str, status: &str) -> Result<(), String> {
    if status == "OK" {
        Ok(())
    } else {
        Err(format!("{endpoint}: daemon status {status:?}"))
    }
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

    async fn get_json<T: DeserializeOwned>(&self, path: &str) -> Result<T, String> {
        self.client
            .get(format!("{}{}", self.base_url, path))
            .send()
            .await
            .map_err(|e| format!("HTTP: {e}"))?
            .json()
            .await
            .map_err(|e| format!("JSON: {e}"))
    }

    async fn post_json<Req: Serialize, Resp: DeserializeOwned>(
        &self,
        path: &str,
        req: &Req,
    ) -> Result<Resp, String> {
        let resp = self
            .client
            .post(format!("{}{}", self.base_url, path))
            .json(req)
            .send()
            .await
            .map_err(|e| format!("HTTP: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("HTTP {} from {}", resp.status(), path));
        }
        resp.json().await.map_err(|e| format!("JSON: {e}"))
    }

    async fn post_bin(&self, path: &str, body: Vec<u8>) -> Result<Vec<u8>, String> {
        let resp = self
            .client
            .post(format!("{}{}", self.base_url, path))
            .header("Content-Type", "application/octet-stream")
            .body(body)
            .send()
            .await
            .map_err(|e| format!("HTTP: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("HTTP {} from {}", resp.status(), path));
        }
        resp.bytes().await.map(|b| b.to_vec()).map_err(|e| format!("body: {e}"))
    }

    async fn json_rpc<T: DeserializeOwned>(
        &self,
        method: &str,
        params: serde_json::Value,
    ) -> Result<T, String> {
        let req = JsonRpcRequest { jsonrpc: "2.0", id: "1", method, params };
        let resp: JsonRpcResponse<T> = self
            .client
            .post(format!("{}/json_rpc", self.base_url))
            .json(&req)
            .send()
            .await
            .map_err(|e| format!("HTTP: {e}"))?
            .json()
            .await
            .map_err(|e| format!("JSON: {e}"))?;
        if let Some(err) = resp.error {
            Err(format!("RPC: {}", err.message))
        } else {
            resp.result.ok_or_else(|| "no result".into())
        }
    }

    pub async fn get_info(&self) -> Result<DaemonInfo, String> {
        self.get_json("/getinfo").await
    }

    pub async fn get_height(&self) -> Result<u64, String> {
        let resp = self
            .json_rpc::<serde_json::Value>("getblockcount", serde_json::json!({}))
            .await?;
        resp.get("count").and_then(|v| v.as_u64()).ok_or_else(|| "missing count".into())
    }

    pub async fn get_block_hash(&self, height: u64) -> Result<String, String> {
        self.json_rpc::<String>("on_getblockhash", serde_json::json!([height])).await
    }

    /// Relay status: "OK", "Failed", or another daemon status string.
    pub async fn send_raw_tx(&self, tx_hex: &str) -> Result<String, String> {
        let resp: SendRawTxResponse = self
            .post_json("/sendrawtransaction", &SendRawTxRequest { tx_as_hex: tx_hex.to_string() })
            .await?;
        Ok(resp.status)
    }

    /// /queryblockslite.bin — incremental block + tx-prefix sync.
    pub async fn query_blocks_lite(
        &self,
        block_ids: &[[u8; 32]],
        timestamp: u64,
    ) -> Result<fuego_sdk::serialization::QueryBlocksLiteResponse, String> {
        use fuego_sdk::serialization::{parse_query_blocks_lite_response, query_blocks_lite_request};
        let resp = self
            .post_bin("/queryblockslite.bin", query_blocks_lite_request(block_ids, timestamp))
            .await?;
        parse_query_blocks_lite_response(&resp).map_err(|e| e.to_string())
    }

    /// /getrandom_outs.bin — decoy outputs for the given amounts.
    pub async fn get_random_outs(
        &self,
        amounts: &[u64],
        outs_count: u64,
    ) -> Result<Vec<fuego_sdk::serialization::RandomOutsForAmount>, String> {
        use fuego_sdk::serialization::{get_random_outs_request, parse_get_random_outs_response};
        let resp = self
            .post_bin("/getrandom_outs.bin", get_random_outs_request(amounts, outs_count))
            .await?;
        parse_get_random_outs_response(&resp).map_err(|e| e.to_string())
    }

    /// /get_o_indexes.bin — global output indices of a transaction.
    pub async fn get_o_indexes(&self, tx_hash: &[u8; 32]) -> Result<Vec<u64>, String> {
        use fuego_sdk::serialization::{get_o_indexes_request, parse_get_o_indexes_response};
        let resp = self.post_bin("/get_o_indexes.bin", get_o_indexes_request(tx_hash)).await?;
        parse_get_o_indexes_response(&resp).map_err(|e| e.to_string())
    }

    /// /getrandom_commitment_outs.bin — decoy commitment outputs for one
    /// amount, created at or below `max_height` (0 = no limit).
    pub async fn get_random_commitment_outs(
        &self,
        amount: u64,
        outs_count: u64,
        max_height: u32,
        ring_class: u8,
    ) -> Result<Vec<fuego_sdk::serialization::RandomCommitmentOutEntry>, String> {
        use fuego_sdk::serialization::{
            get_random_commitment_outs_request, parse_get_random_commitment_outs_response,
        };
        let resp = self
            .post_bin(
                "/getrandom_commitment_outs.bin",
                get_random_commitment_outs_request(amount, outs_count, max_height, ring_class),
            )
            .await?;
        parse_get_random_commitment_outs_response(&resp).map_err(|e| e.to_string())
    }

    /// /amm_pool_info — Hearth pool reserves, spot price and 8-block TWAP.
    pub async fn amm_pool_info(&self) -> Result<AmmPoolInfoResponse, String> {
        let resp: AmmPoolInfoResponse = self.post_json("/amm_pool_info", &AmmPoolInfoRequest {}).await?;
        require_ok("/amm_pool_info", &resp.status)?;
        Ok(resp)
    }

    /// /estimate_cd_yield — pool-aware CD interest estimate (v11+ splits
    /// base and Bonus-Vault bonus).
    pub async fn estimate_cd_yield(
        &self,
        amount: u64,
        creation_height: u32,
        term: u32,
    ) -> Result<EstimateCdYieldResponse, String> {
        let req = EstimateCdYieldRequest { amount, creation_height, current_height: 0, term };
        let resp: EstimateCdYieldResponse = self.post_json("/estimate_cd_yield", &req).await?;
        require_ok("/estimate_cd_yield", &resp.status)?;
        Ok(resp)
    }

    /// /is_key_image_spent.
    pub async fn is_key_image_spent(&self, key_image: &[u8; 32]) -> Result<bool, String> {
        let req = IsKeyImageSpentRequest { key_image: hex::encode(key_image) };
        let resp: IsKeyImageSpentResponse = self.post_json("/is_key_image_spent", &req).await?;
        require_ok("/is_key_image_spent", &resp.status)?;
        Ok(resp.spent)
    }

    /// /get_alias — registration lookup for an @alias.
    pub async fn get_alias(&self, alias: &str) -> Result<GetAliasResponse, String> {
        self.post_json("/get_alias", &GetAliasRequest { alias: alias.to_string() }).await
    }
}
