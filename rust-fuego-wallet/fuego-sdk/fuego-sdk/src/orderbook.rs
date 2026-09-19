use serde::{Deserialize, Serialize};
use crate::error::{Result, SdkError};
use crate::types::*;

/// Orderbook RPC client wrapping fuegod daemon endpoints.
pub struct OrderbookClient {
    endpoint: String,
    client: reqwest::Client,
}

impl OrderbookClient {
    pub fn new(endpoint: impl Into<String>) -> Self {
        Self {
            endpoint: endpoint.into(),
            client: reqwest::Client::new(),
        }
    }

    // ── Swap Offers ───────────────────────────────────────────────────

    /// Offers for `pair`. The daemon keys on the numeric id, so this is safe
    /// for every pair; the string form has six divergences from the ticker
    /// (see [`SwapPair::daemon_name`]).
    pub async fn get_offers(&self, pair: SwapPair) -> Result<Vec<SwapOffer>> {
        let resp: OfferResponse = self.post("/getswapoffers", serde_json::json!({
            "pair": pair as u8,
        })).await?;
        Ok(resp.offers)
    }

    pub async fn get_price(&self, pair: SwapPair) -> Result<SwapPriceResponse> {
        self.post("/getswapprice", serde_json::json!({
            "pair": pair as u8,
        })).await
    }

    pub async fn get_trades(&self, pair: SwapPair, limit: u32) -> Result<Vec<SwapTrade>> {
        let resp: TradesResponse = self.post("/getswaptrades", serde_json::json!({
            "pair": pair as u8,
            "limit": limit,
        })).await?;
        Ok(resp.trades)
    }

    pub async fn submit_offer(&self, offer: &SignedOffer) -> Result<()> {
        let _: serde_json::Value = self.post("/submitswap", serde_json::to_value(offer)?).await?;
        Ok(())
    }

    pub async fn cancel_offer(&self, offer_id: &str, maker_pubkey: &str, signature: &str) -> Result<()> {
        let _: serde_json::Value = self.post("/cancelswap", serde_json::json!({
            "offerId": offer_id,
            "makerPubKey": maker_pubkey,
            "signature": signature,
        })).await?;
        Ok(())
    }

    pub async fn request_swap(
        &self,
        offer_id: &str,
        amount: u64,
        taker_pubkey: &str,
        proof_of_funds: &str,
    ) -> Result<()> {
        let _: serde_json::Value = self.post("/requestswap", serde_json::json!({
            "offerId": offer_id,
            "amount": amount,
            "takerPubKey": taker_pubkey,
            "proofOfFunds": proof_of_funds,
        })).await?;
        Ok(())
    }

    pub async fn get_active_swaps(&self) -> Result<Vec<SwapStatus>> {
        let resp: ActiveSwapsResponse = self.post("/getactiveswaps", serde_json::Value::Null).await?;
        Ok(resp.swaps)
    }

    pub async fn get_swap_status(&self, swap_id: &str) -> Result<SwapStatus> {
        self.post("/getswapstatus", serde_json::json!({
            "swapId": swap_id,
        })).await
    }

    // ── Orderbook State ───────────────────────────────────────────────

    pub async fn get_orderbook_state(&self, depth: u32) -> Result<OrderBookState> {
        self.get(&format!("/get_orderbook_state?depth={depth}")).await
    }

    pub async fn get_fuego_price(&self) -> Result<FuegoPrice> {
        self.get("/get_fuego_price").await
    }

    // ── Hearth ────────────────────────────────────────────────────────
    //
    // Hearth is the pool. The `amm_` in the endpoint names is fuegod's own
    // shorthand for it — `RpcServer.cpp:210` labels the block
    // "HEAT / Hearth AMM endpoints", and both endpoints call
    // `getAmmPoolInfo()` and return `hearth_twap`. There is one pool, so the
    // wire names stay as the daemon spells them and everything on this side
    // is named Hearth.

    /// Hearth quote.
    ///
    /// `COMMAND_RPC_AMM_QUOTE::request` is `{input_amount: u64, direction: u8}`
    /// read from the request BODY — fuegod's `jsonMethod` handler calls
    /// `loadFromJson(req, request.getBody())` and never looks at the query
    /// string. This used to be a GET of `?sell_xfg=&amount=`, which the daemon
    /// parsed as all-zeros.
    ///
    /// `input_amount` is atomic units (COIN = 10^7 for both XFG and HEAT);
    /// `direction` is 0 for XFG→HEAT and 1 for HEAT→XFG.
    pub async fn get_hearth_quote(&self, sell_xfg: bool, input_amount: u64) -> Result<HearthQuote> {
        self.post(
            "/amm_quote",
            serde_json::json!({
                "input_amount": input_amount,
                "direction": if sell_xfg { 0 } else { 1 },
            }),
        )
        .await
    }

    pub async fn get_hearth_pool(&self) -> Result<HearthPool> {
        self.post("/amm_pool_info", serde_json::json!({})).await
    }

    /// Hearth ΗΞΔŦ metrics.
    pub async fn get_heat_metrics(&self) -> Result<serde_json::Value> {
        self.post("/heat_metrics", serde_json::json!({})).await
    }

    // ── HTTP helpers ──────────────────────────────────────────────────

    async fn post<T: serde::de::DeserializeOwned>(&self, path: &str, body: serde_json::Value) -> Result<T> {
        let resp = self.client
            .post(format!("{}{}", self.endpoint, path))
            .json(&body)
            .send()
            .await
            .map_err(|e| SdkError::Network(format!("HTTP request failed: {e}")))?;

        let status = resp.status();
        let text = resp.text().await
            .map_err(|e| SdkError::Network(format!("Failed to read response: {e}")))?;

        if !status.is_success() {
            return Err(SdkError::Network(format!("RPC {path} returned {status}: {text}")));
        }

        serde_json::from_str(&text)
            .map_err(|e| SdkError::Serialization(format!("Failed to decode {}: {} (body: {})", path, e, &text[..text.len().min(200)])))
    }

    async fn get<T: serde::de::DeserializeOwned>(&self, path: &str) -> Result<T> {
        let resp = self.client
            .get(format!("{}{}", self.endpoint, path))
            .send()
            .await
            .map_err(|e| SdkError::Network(format!("HTTP request failed: {e}")))?;

        let status = resp.status();
        let text = resp.text().await
            .map_err(|e| SdkError::Network(format!("Failed to read response: {e}")))?;

        if !status.is_success() {
            return Err(SdkError::Network(format!("GET {path} returned {status}: {text}")));
        }

        serde_json::from_str(&text)
            .map_err(|e| SdkError::Serialization(format!("Failed to decode {path}: {e}")))
    }
}

// ── Response types ─────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OfferResponse {
    pub offers: Vec<SwapOffer>,
    #[serde(default)]
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TradesResponse {
    pub trades: Vec<SwapTrade>,
    #[serde(default)]
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActiveSwapsResponse {
    pub swaps: Vec<SwapStatus>,
    #[serde(default)]
    pub status: String,
}

/// Response of `/amm_quote`.
///
/// Field names are `COMMAND_RPC_AMM_QUOTE::response`
/// (`CoreRpcServerCommandsDefinitions.h:2521-2532`). The previous shape
/// (`sell_xfg` / `input_amount` / `output_amount` / `price_impact`) matched no
/// struct fuegod serializes, so every field deserialized as missing.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HearthQuote {
    /// Atomic units.
    #[serde(default)]
    pub expected_output: u64,
    #[serde(default)]
    pub price_impact_bps: u64,
    /// Atomic units.
    #[serde(default)]
    pub fee: u64,
    #[serde(default)]
    pub status: String,
}

/// Response of `/amm_pool_info` — `COMMAND_RPC_AMM_POOL_INFO::response`
/// (`CoreRpcServerCommandsDefinitions.h:2538-2557`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HearthPool {
    #[serde(default)]
    pub reserve_xfg: u64,
    #[serde(default)]
    pub reserve_heat: u64,
    #[serde(default)]
    pub total_lp_shares: u64,
    /// HEAT-per-XFG scaled by COIN, so the human ratio is `spot_price / 1e7`.
    #[serde(default)]
    pub spot_price: u64,
    #[serde(default)]
    pub epoch_swap_fees: u64,
    #[serde(default)]
    pub hearth_twap: u64,
    #[serde(default)]
    pub height: u64,
    #[serde(default)]
    pub status: String,
}

impl HearthPool {
    /// HEAT per XFG.
    pub fn heat_per_xfg(&self) -> f64 {
        self.spot_price as f64 / 10_000_000.0
    }

    /// True when the pool is seeded and a rate can be quoted at all.
    pub fn is_seeded(&self) -> bool {
        self.reserve_xfg > 0 && self.reserve_heat > 0 && self.spot_price > 0
    }

    /// HEAT a burn of `xfg_atomic` mints, by the rule walletd and consensus
    /// both apply: `xfg_burned * spot_price / COIN`. `None` when unseeded —
    /// naming a HEAT amount without a pool price is how a mint gets rejected.
    pub fn heat_for_burn(&self, xfg_atomic: u64) -> Option<u64> {
        if !self.is_seeded() {
            return None;
        }
        Some(((xfg_atomic as u128 * self.spot_price as u128) / 10_000_000u128) as u64)
    }
}
