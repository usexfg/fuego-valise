use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use fuego_sdk::suite::rpc::{self, Transport};
use fuego_sdk::suite::walletd;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::wallet_service::{SendOptions, WalletService};

pub struct AppState {
    pub wallet: Arc<Mutex<WalletService>>,
    pub fuegod_url: String,
}

#[derive(Serialize)]
struct JsonRpcSuccess {
    jsonrpc: &'static str,
    id: Value,
    result: Value,
}

#[derive(Serialize)]
struct JsonRpcError {
    jsonrpc: &'static str,
    id: Value,
    error: RpcErrorDetail,
}

#[derive(Serialize)]
struct RpcErrorDetail {
    code: i32,
    message: String,
}

/// fuegod routes the proxy never forwards (node control / fee admin).
const FUEGOD_DENY: &[&str] = &["stop_daemon", "addswapfee", "submitblock"];

fn is_wallet_method(method: &str) -> bool {
    matches!(
        method,
        "getBalance" | "getbalance" | "getAddresses" | "getAddress" | "get_address" | "getHealth"
            | "getStatus" | "get_height" | "getTransactions" | "get_transfers" | "sendTransaction"
            | "transfer" | "register_alias" | "createIntegrated" | "create_integrated" | "list_cds"
            | "cd::list" | "cd::create" | "create_cd" | "cd::claim" | "claim_cd" | "create_afk_lock"
            | "send_heat" | "get_tx_proof" | "getTxProof" | "mint_heat" | "swap" | "add_liq"
            | "remove_liq" | "place_limit_order" | "heat_cd"
    )
}

fn sanitize_error(msg: &str) -> String {
    if msg.contains("127.0.0.1")
        || msg.contains("localhost")
        || msg.contains("/Users/")
        || msg.contains("/home/")
        || msg.contains("http://")
        || msg.contains("https://")
    {
        return "internal error".to_string();
    }
    msg.trim_start_matches("HTTP: ")
        .trim_start_matches("JSON: ")
        .trim_start_matches("RPC: ")
        .to_string()
}

fn to_value<T: Serialize>(v: &T) -> Result<Value, String> {
    serde_json::to_value(v).map_err(|e| e.to_string())
}

/// u64 from a JSON number or decimal string.
fn param_u64(params: &Value, key: &str) -> Option<u64> {
    let v = params.get(key)?;
    v.as_u64().or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
}

async fn read_json(resp: reqwest::Response) -> Result<Value, String> {
    let text = resp
        .text()
        .await
        .map_err(|e| sanitize_error(&format!("fuego daemon response: {}", e)))?;
    Ok(serde_json::from_str(&text).unwrap_or_else(|_| json!({ "status": text.trim() })))
}

/// Forward a method to fuegod using the transport fuegod registers for it
/// (generated from RpcServer.cpp): `/json_rpc` methods go through the
/// JSON-RPC dispatcher, HTTP JSON endpoints get the params as their body.
async fn proxy_to_fuegod(fuegod_url: &str, method: &str, params: Value) -> Result<Value, String> {
    if FUEGOD_DENY.contains(&method) {
        return Err(format!("{method} is not available through the wallet proxy"));
    }
    let client = reqwest::Client::new();
    let net = |e: reqwest::Error| sanitize_error(&format!("fuego daemon: {}", e));

    if rpc::is_json_rpc_method(method) {
        let body = json!({ "jsonrpc": "2.0", "id": "0", "method": method, "params": params });
        let resp = read_json(client.post(format!("{fuegod_url}/json_rpc")).json(&body).send().await.map_err(net)?).await?;
        if let Some(err) = resp.get("error").filter(|e| !e.is_null()) {
            return Err(err.get("message").and_then(Value::as_str).unwrap_or("fuegod error").to_string());
        }
        return Ok(resp.get("result").cloned().unwrap_or(Value::Null));
    }

    // Wallet-facing alias: fuegod serves the orderbook at /getorderbook.
    let path = match method {
        "get_orderbook_state" => "/getorderbook".to_string(),
        other => format!("/{other}"),
    };
    let body = if params.is_null() { json!({}) } else { params };
    match rpc::http_route(&path) {
        Some(Transport::Json) | Some(Transport::JsonSwapAuth) => {
            read_json(client.post(format!("{fuegod_url}{path}")).json(&body).send().await.map_err(net)?).await
        }
        Some(Transport::Binary) | Some(Transport::JsonRpc) => {
            Err(format!("{path} is not a JSON endpoint"))
        }
        None => Err(format!("fuegod has no method {method}")),
    }
}

fn walletd_transactions(
    history: &[fuego_sdk::scanner::HistoryEntry],
    height: u64,
    params: &Value,
) -> Result<walletd::GetTransactionsResponse, String> {
    let first = param_u64(params, "firstBlockIndex").unwrap_or(0);
    let count = param_u64(params, "blockCount").unwrap_or(u64::MAX);
    let payment_filter = params.get("paymentId").and_then(Value::as_str).filter(|s| !s.is_empty());
    let mut blocks: BTreeMap<u64, Vec<walletd::TransactionRpcInfo>> = BTreeMap::new();
    for tx in history {
        if tx.block_height < first || tx.block_height - first >= count {
            continue;
        }
        let payment_id = tx.payment_id.map(hex::encode).unwrap_or_default();
        if payment_filter.is_some_and(|p| !p.eq_ignore_ascii_case(&payment_id)) {
            continue;
        }
        blocks.entry(tx.block_height).or_default().push(walletd::TransactionRpcInfo {
            state: 0,
            transaction_hash: hex::encode(tx.tx_hash),
            block_index: u32::try_from(tx.block_height).map_err(|_| "block index overflow")?,
            confirmations: height.saturating_sub(tx.block_height).saturating_add(1).min(u32::MAX as u64) as u32,
            timestamp: tx.timestamp,
            is_base: false,
            unlock_time: tx.unlock_time,
            amount: tx.signed_amount(),
            fee: tx.fee,
            transfers: Vec::new(),
            extra: String::new(),
            first_deposit_id: u64::MAX,
            deposit_count: 0,
            payment_id,
        });
    }
    Ok(walletd::GetTransactionsResponse {
        items: blocks
            .into_values()
            .map(|transactions| walletd::TransactionsInBlockRpcInfo { block_hash: String::new(), transactions })
            .collect(),
    })
}

async fn handle_wallet_method(
    wallet: &Mutex<WalletService>,
    fuegod_url: &str,
    method: &str,
    params: &Value,
) -> Result<Value, String> {
    match method {
        "getBalance" | "getbalance" => {
            let b = wallet.lock().await.balance_breakdown();
            to_value(&walletd::GetBalanceResponse {
                available_balance: b.unlocked_xfg,
                locked_amount: b.locked_xfg,
                locked_deposit_balance: b.locked_deposits,
                unlocked_deposit_balance: b.unlocked_deposits,
                locked_heat_balance: b.locked_heat,
                unlocked_heat_balance: b.unlocked_heat,
            })
        }
        "getAddresses" => {
            let wallet = wallet.lock().await;
            to_value(&walletd::GetAddressesResponse { addresses: vec![wallet.address().await] })
        }
        "getAddress" | "get_address" => {
            let wallet = wallet.lock().await;
            Ok(json!({ "address": wallet.address().await }))
        }
        "getHealth" => {
            let wallet = wallet.lock().await;
            let status = wallet.sync_status();
            Ok(json!({
                "wallet": { "ok": true, "height": status.current_height, "syncing": status.is_syncing },
                "swap": { "ok": crate::swapd::swapd_healthy(crate::swapd::SWAPD_RPC_PORT).await },
            }))
        }
        "getStatus" | "get_height" => {
            let (status, txs, cds) = {
                let wallet = wallet.lock().await;
                (wallet.sync_status(), wallet.get_transactions(usize::MAX).await.len(), wallet.cds().len())
            };
            let peers = proxy_to_fuegod(fuegod_url, "getinfo", Value::Null).await.ok();
            let peer_count = peers
                .map(|i| {
                    i.get("incoming_connections_count").and_then(Value::as_u64).unwrap_or(0)
                        + i.get("outgoing_connections_count").and_then(Value::as_u64).unwrap_or(0)
                })
                .unwrap_or(0);
            to_value(&walletd::GetStatusResponse {
                block_count: (status.current_height + 1).min(u32::MAX as u64) as u32,
                known_block_count: status.target_height.min(u32::MAX as u64) as u32,
                last_block_hash: String::new(),
                peer_count: peer_count.min(u32::MAX as u64) as u32,
                deposit_count: cds as u32,
                transaction_count: txs as u32,
                address_count: 1,
            })
        }
        "getTransactions" | "get_transfers" => {
            let wallet = wallet.lock().await;
            let height = wallet.height().await;
            let history = wallet.get_transactions(usize::MAX).await;
            to_value(&walletd_transactions(&history, height, params)?)
        }
        "sendTransaction" | "transfer" => {
            // walletd names the list `transfers`; the simplewallet `transfer`
            // method names it `destinations`.
            let list = params
                .get("transfers")
                .or_else(|| params.get("destinations"))
                .and_then(Value::as_array)
                .ok_or("missing transfers")?;
            let mut dests: Vec<(String, u64)> = Vec::with_capacity(list.len());
            for dest in list {
                let address = dest.get("address").and_then(Value::as_str).ok_or("missing address")?.to_string();
                let amount = param_u64(dest, "amount").ok_or("missing amount")?;
                dests.push((address, amount));
            }
            let fee = param_u64(params, "fee").unwrap_or(fuego_sdk::suite::MINIMUM_FEE);
            let anonymity = param_u64(params, "anonymity")
                .or_else(|| param_u64(params, "mixin"))
                .unwrap_or(0)
                .min(u32::MAX as u64) as u32;
            let opts = SendOptions {
                payment_id: params
                    .get("paymentId")
                    .or_else(|| params.get("payment_id"))
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string),
                extra_hex: params.get("extra").and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string),
                unlock_time: param_u64(params, "unlockTime").unwrap_or(0),
            };
            let wallet = wallet.lock().await;
            let tx_hash = wallet
                .send_transaction(&dests, fee, anonymity, opts)
                .await
                .map_err(|e| format!("send failed: {}", e))?;
            to_value(&walletd::SendTransactionResponse { transaction_hash: tx_hash, transaction_secret_key: String::new() })
        }
        "register_alias" => {
            let alias = params.get("alias").and_then(Value::as_str).ok_or("missing alias")?;
            let wallet = wallet.lock().await;
            let tx_hash = wallet.register_alias(alias).await.map_err(|e| format!("alias registration failed: {}", e))?;
            Ok(json!({ "transactionHash": tx_hash }))
        }
        "createIntegrated" | "create_integrated" => {
            let payment_id = params.get("payment_id").and_then(Value::as_str).ok_or("missing payment_id")?;
            let address = params.get("address").and_then(Value::as_str);
            let integrated = wallet.lock().await.create_integrated(address, payment_id)?;
            to_value(&walletd::CreateIntegratedResponse { integrated_address: integrated })
        }
        "list_cds" | "cd::list" => {
            // Estimates run after the wallet lock is released.
            let (owner, height, entries) = {
                let wallet = wallet.lock().await;
                let height = wallet.height().await;
                let entries: Vec<_> = wallet
                    .cds()
                    .into_iter()
                    .map(|v| {
                        let est = wallet.cd_interest_estimate_inputs(&v);
                        (v, est)
                    })
                    .collect();
                (wallet.address().await, height, entries)
            };
            let mut cds = Vec::with_capacity(entries.len());
            for (v, est) in entries {
                let accrued = match est {
                    Some((daemon, amount, created, term)) => daemon
                        .estimate_cd_yield(amount, created, term)
                        .await
                        .map(|e| e.claimable_interest)
                        .unwrap_or(0),
                    None => 0,
                };
                cds.push(json!({
                    "cd_id": v.cd_id,
                    "owner": owner,
                    "coin": "HEAT",
                    "amount": v.amount.to_string(),
                    "maturity_height": v.maturity_height,
                    "deposit_height": v.deposit_height,
                    "accrued_interest": accrued.to_string(),
                    "total_value": (v.amount + accrued).to_string(),
                    "blocks_to_maturity": v.maturity_height.saturating_sub(height),
                    "matured": v.matured,
                }));
            }
            Ok(json!({ "cds": cds }))
        }
        "cd::create" | "create_cd" => {
            let amount = param_u64(params, "amount").ok_or("missing amount")?;
            let duration = param_u64(params, "duration_blocks").ok_or("missing duration_blocks")?;
            let term = u32::try_from(duration).map_err(|_| "duration_blocks out of range")?;
            let wallet = wallet.lock().await;
            let (tx_hash, cd_id, maturity) =
                wallet.create_cd(amount, term).await.map_err(|e| format!("create_cd failed: {}", e))?;
            Ok(json!({
                "cd_id": cd_id,
                "tx_hash": tx_hash,
                "coin": "HEAT",
                "amount": amount.to_string(),
                "maturity_at": maturity.to_string(),
            }))
        }
        "cd::claim" | "claim_cd" => {
            let only = params.get("cd_id").and_then(Value::as_str).filter(|s| !s.is_empty());
            let wallet = wallet.lock().await;
            let claim = wallet.claim_cd(only).await.map_err(|e| format!("claim_cd failed: {}", e))?;
            Ok(json!({
                "cd_id": claim.cd_ids.join(","),
                "tx_hash": claim.tx_hash,
                "coin": "HEAT",
                "principal": claim.principal.to_string(),
                "interest": claim.interest.to_string(),
                "total": (claim.principal + claim.interest).to_string(),
            }))
        }
        "create_afk_lock" => {
            let amount = param_u64(params, "amount").ok_or("missing amount")?;
            let hours = param_u64(params, "timeout_hours").ok_or("missing timeout_hours")?;
            let pair = param_u64(params, "pair").unwrap_or(0);
            let wallet = wallet.lock().await;
            let (lock_id, adaptor_point, pre_sig, hash_lock) = wallet
                .create_afk_lock(amount, hours.min(u32::MAX as u64) as u32, pair.min(u8::MAX as u64) as u8)
                .await
                .map_err(|e| format!("create_afk_lock failed: {}", e))?;
            Ok(json!({ "lockId": lock_id, "adaptorPoint": adaptor_point, "preSig": pre_sig, "hashLock": hash_lock }))
        }
        "send_heat" => {
            let address = params.get("address").and_then(Value::as_str).ok_or("missing address")?;
            let amount = param_u64(params, "amount").ok_or("missing amount")?;
            let wallet = wallet.lock().await;
            let tx_hash = wallet.send_heat(address, amount).await.map_err(|e| format!("send_heat failed: {}", e))?;
            Ok(json!({ "transactionHash": tx_hash }))
        }
        "get_tx_proof" | "getTxProof" => {
            let tx_hash = params
                .get("tx_hash")
                .or_else(|| params.get("txid"))
                .and_then(Value::as_str)
                .ok_or("missing tx_hash")?;
            let address = params.get("address").and_then(Value::as_str).ok_or("missing address")?;
            let wallet = wallet.lock().await;
            let proof = wallet.get_tx_proof(tx_hash, address).await.map_err(|e| format!("get_tx_proof failed: {}", e))?;
            Ok(json!({ "signature": proof }))
        }
        "mint_heat" => {
            let xfg_burned = param_u64(params, "xfg_burned")
                .or_else(|| param_u64(params, "amount"))
                .ok_or("missing xfg_burned")?;
            let wallet = wallet.lock().await;
            let (tx_hash, heat_minted, price) =
                wallet.mint_heat(xfg_burned).await.map_err(|e| format!("mint_heat failed: {}", e))?;
            Ok(json!({ "transactionHash": tx_hash, "xfgBurned": xfg_burned, "heatMinted": heat_minted, "price": price }))
        }
        "swap" => {
            let direction = match params.get("direction").and_then(Value::as_str).unwrap_or("") {
                "heat_to_xfg" | "1" => 1u8,
                _ => 0u8,
            };
            let input_amount = param_u64(params, "input_amount").ok_or("missing input_amount")?;
            let min_output = param_u64(params, "min_output").unwrap_or(0);
            let wallet = wallet.lock().await;
            let tx_hash = wallet
                .amm_swap(direction, input_amount, min_output)
                .await
                .map_err(|e| format!("swap failed: {}", e))?;
            Ok(json!({ "transactionHash": tx_hash }))
        }
        "add_liq" => {
            let xfg = param_u64(params, "xfg_amount").ok_or("missing xfg_amount")?;
            let heat = param_u64(params, "heat_amount").ok_or("missing heat_amount")?;
            let wallet = wallet.lock().await;
            let tx_hash = wallet.lp_add(xfg, heat).await.map_err(|e| format!("add_liq failed: {}", e))?;
            Ok(json!({ "transactionHash": tx_hash }))
        }
        "remove_liq" => {
            let shares = param_u64(params, "shares").ok_or("missing shares")?;
            let min_xfg = param_u64(params, "min_xfg").unwrap_or(0);
            let min_heat = param_u64(params, "min_heat").unwrap_or(0);
            let wallet = wallet.lock().await;
            let tx_hash = wallet
                .lp_remove(shares, min_xfg, min_heat)
                .await
                .map_err(|e| format!("remove_liq failed: {}", e))?;
            Ok(json!({ "transactionHash": tx_hash }))
        }
        "place_limit_order" => {
            let side = match params.get("side").and_then(Value::as_str).unwrap_or("sell") {
                "buy" | "0" => 0u8,
                _ => 1u8,
            };
            let amount = param_u64(params, "amount").ok_or("missing amount")?;
            // Human HEAT-per-XFG decimal -> canonical price (HEAT atomics per
            // XFG atomic × COIN), the scale OrderbookMatcher/limit deposits use.
            let price_atomic = params
                .get("price")
                .and_then(Value::as_str)
                .and_then(|s| s.parse::<f64>().ok())
                .filter(|p| p.is_finite() && *p > 0.0)
                .map(|p| (p * fuego_sdk::suite::COIN as f64).round() as u64)
                .or_else(|| params.get("price").and_then(Value::as_u64))
                .ok_or("missing price")?;
            let expiration = param_u64(params, "ttlBlocks")
                .or_else(|| param_u64(params, "expiration"))
                .unwrap_or(8640)
                .min(u32::MAX as u64) as u32;
            let wallet = wallet.lock().await;
            let tx_hash = wallet
                .place_limit_order(side, amount, price_atomic, expiration)
                .await
                .map_err(|e| format!("place_limit_order failed: {}", e))?;
            Ok(json!({ "transactionHash": tx_hash }))
        }
        "heat_cd" => {
            let amount = param_u64(params, "amount").ok_or("missing amount")?;
            let epochs = param_u64(params, "epochs").ok_or("missing epochs")?;
            let banking_fee = param_u64(params, "banking_fee").unwrap_or(0);
            let wallet = wallet.lock().await;
            let tx_hash = wallet
                .heat_cd(amount, epochs.min(u32::MAX as u64) as u32, banking_fee)
                .await
                .map_err(|e| format!("heat_cd failed: {}", e))?;
            Ok(json!({ "transactionHash": tx_hash }))
        }
        _ => Err(format!("unknown wallet method: {}", method)),
    }
}

fn is_authorized_host(headers: &axum::http::HeaderMap) -> bool {
    match headers.get(axum::http::header::HOST).map(|h| h.to_str()) {
        Some(Ok(host)) => {
            let host = host.rsplit_once(':').map(|(h, _)| h).unwrap_or(host).to_lowercase();
            matches!(host.as_str(), "localhost" | "127.0.0.1" | "[::1]" | "")
        }
        Some(Err(_)) => false,
        None => true,
    }
}

async fn json_rpc_handler(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    Json(body): Json<Value>,
) -> impl IntoResponse {
    let id = body.get("id").cloned().unwrap_or(Value::Null);
    let method = body.get("method").and_then(Value::as_str).unwrap_or("");

    if !is_authorized_host(&headers) {
        let error = JsonRpcError {
            jsonrpc: "2.0",
            id,
            error: RpcErrorDetail { code: -32500, message: "forbidden host".into() },
        };
        return (StatusCode::FORBIDDEN, Json(serde_json::to_value(error).unwrap())).into_response();
    }

    let params = body.get("params").cloned().unwrap_or(Value::Null);
    let result = if is_wallet_method(method) {
        handle_wallet_method(&state.wallet, &state.fuegod_url, method, &params).await
    } else {
        proxy_to_fuegod(&state.fuegod_url, method, params).await
    };

    match result {
        Ok(result) => {
            let ok = JsonRpcSuccess { jsonrpc: "2.0", id, result };
            (StatusCode::OK, Json(serde_json::to_value(ok).unwrap())).into_response()
        }
        Err(message) => {
            let err = JsonRpcError { jsonrpc: "2.0", id, error: RpcErrorDetail { code: -32000, message } };
            (StatusCode::OK, Json(serde_json::to_value(err).unwrap())).into_response()
        }
    }
}

// ── REST passthrough to fuegod JSON endpoints ──

/// Query parameters become the JSON body fuegod's jsonMethod handlers read
/// (they ignore the query string). Numeric strings are sent as numbers.
fn query_to_body(query: &HashMap<String, String>) -> Value {
    let mut body = serde_json::Map::new();
    for (k, v) in query {
        let value = v
            .parse::<u64>()
            .map(Value::from)
            .or_else(|_| v.parse::<i64>().map(Value::from))
            .unwrap_or_else(|_| match v.as_str() {
                "true" => Value::Bool(true),
                "false" => Value::Bool(false),
                _ => Value::String(v.clone()),
            });
        body.insert(k.clone(), value);
    }
    Value::Object(body)
}

async fn forward_rest(state: &AppState, path: &str, body: Value) -> axum::response::Response {
    let method = path.trim_start_matches('/');
    let result = if method == "getinfo" {
        reqwest::Client::new()
            .get(format!("{}/getinfo", state.fuegod_url))
            .send()
            .await
            .map_err(|e| sanitize_error(&e.to_string()))
    } else {
        reqwest::Client::new()
            .post(format!("{}{}", state.fuegod_url, path))
            .json(&body)
            .send()
            .await
            .map_err(|e| sanitize_error(&e.to_string()))
    };
    match result {
        Ok(r) => {
            let status = StatusCode::from_u16(r.status().as_u16()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
            match read_json(r).await {
                Ok(v) => (status, Json(v)).into_response(),
                Err(e) => (StatusCode::BAD_GATEWAY, Json(json!({ "error": e }))).into_response(),
            }
        }
        Err(e) => (StatusCode::BAD_GATEWAY, Json(json!({ "error": e }))).into_response(),
    }
}

async fn fuegod_get(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    uri: axum::http::Uri,
    Query(query): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    if !is_authorized_host(&headers) {
        return (StatusCode::FORBIDDEN, Json(json!({ "error": "forbidden host" }))).into_response();
    }
    forward_rest(&state, uri.path(), query_to_body(&query)).await
}

async fn fuegod_post(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    uri: axum::http::Uri,
    body: axum::body::Bytes,
) -> impl IntoResponse {
    if !is_authorized_host(&headers) {
        return (StatusCode::FORBIDDEN, Json(json!({ "error": "forbidden host" }))).into_response();
    }
    let body: Value = serde_json::from_slice(&body).unwrap_or_else(|_| json!({}));
    forward_rest(&state, uri.path(), body).await
}

// ── HTLC helpers served locally (fuegod has no such endpoints) ──

async fn htlc_hash_lock(headers: axum::http::HeaderMap) -> impl IntoResponse {
    if !is_authorized_host(&headers) {
        return (StatusCode::FORBIDDEN, Json(json!({ "error": "forbidden host" }))).into_response();
    }
    let (preimage, hash) = fuego_sdk::Wallet::create_htlc_hash_lock();
    Json(json!({ "preimage": hex::encode(preimage), "hash": hash })).into_response()
}

async fn htlc_build_script(headers: axum::http::HeaderMap, Json(body): Json<Value>) -> impl IntoResponse {
    if !is_authorized_host(&headers) {
        return (StatusCode::FORBIDDEN, Json(json!({ "error": "forbidden host" }))).into_response();
    }
    let s = |k: &str| body.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let result = fuego_sdk::Wallet::build_htlc_script(
        &s("hash_lock"),
        &s("recipient_pubkey"),
        &s("sender_pubkey"),
        param_u64(&body, "timelock").unwrap_or(0),
    );
    match result {
        Ok(script) => Json(json!({ "ok": true, "script": hex::encode(script) })).into_response(),
        Err(e) => Json(json!({ "ok": false, "script": "", "error": e.to_string() })).into_response(),
    }
}

// ── Status endpoints ──

async fn status_handler(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let wallet = state.wallet.lock().await;
    let b = wallet.balance_breakdown();
    let status = wallet.sync_status();
    Json(json!({
        "address": wallet.address().await,
        "balance": b.unlocked_xfg,
        "pending": b.locked_xfg,
        "immature": 0,
        "height": status.current_height,
        "target_height": status.target_height,
        "is_syncing": status.is_syncing,
    }))
}

async fn health_check(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let fuegod_ok = reqwest::Client::new()
        .get(format!("{}/getinfo", state.fuegod_url))
        .send()
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false);

    let wallet = state.wallet.lock().await;
    let status = wallet.sync_status();
    Json(json!({
        "status": if fuegod_ok { "ok" } else { "degraded" },
        "fuego": fuegod_ok,
        "daemon": fuegod_ok,
        "swap": crate::swapd::swapd_healthy(crate::swapd::SWAPD_RPC_PORT).await,
        "wallet": {
            "address": wallet.address().await,
            "balance": wallet.balance().await,
            "height": status.current_height,
            "syncing": status.is_syncing,
        },
        "scanned_height": status.current_height,
    }))
}

async fn scan_balance_handler(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let wallet = state.wallet.lock().await;
    let b = wallet.balance_breakdown();
    let status = wallet.sync_status();
    Json(json!({
        "balance": b.unlocked_xfg + b.locked_xfg,
        "unlocked_balance": b.unlocked_xfg,
        "pending": b.locked_xfg,
        "immature": 0,
        "height": status.current_height,
        "scanned_height": status.current_height,
        "address": wallet.address().await,
    }))
}

pub async fn run_server(wallet: Arc<Mutex<WalletService>>, fuegod_url: &str, bind_addr: &str) -> Result<(), String> {
    let state = Arc::new(AppState { wallet, fuegod_url: fuegod_url.to_string() });

    let cors = tower_http::cors::CorsLayer::new()
        .allow_origin([
            "http://localhost:18189".parse().unwrap(),
            "http://127.0.0.1:18189".parse().unwrap(),
            "http://localhost:8080".parse().unwrap(),
        ])
        .allow_methods(tower_http::cors::Any)
        .allow_headers(tower_http::cors::Any);

    let app = Router::new()
        .route("/json_rpc", post(json_rpc_handler))
        .route("/health", get(health_check))
        .route("/status", get(status_handler))
        .route("/scan_balance", post(scan_balance_handler))
        .route("/htlc_create_hash_lock", post(htlc_hash_lock))
        .route("/htlc_build_script", post(htlc_build_script))
        // Hearth AMM
        .route("/amm_pool_info", get(fuegod_get))
        .route("/amm_quote", get(fuegod_get))
        .route("/heat_metrics", get(fuegod_get))
        .route("/get_fuego_price", get(fuegod_get))
        .route("/get_limit_orders", get(fuegod_get))
        // Orderbook
        .route("/getorderbook", get(fuegod_get))
        // DEX / swap (GET)
        .route("/getswapoffers", get(fuegod_get))
        .route("/getswapprice", get(fuegod_get))
        .route("/getswaptrades", get(fuegod_get))
        .route("/getswaprequests", get(fuegod_get))
        .route("/getactiveswaps", get(fuegod_get))
        .route("/getswapstatus", get(fuegod_get))
        .route("/listswaps", get(fuegod_get))
        .route("/getinfo", get(fuegod_get))
        // DEX / swap (POST)
        .route("/submitswap", post(fuegod_post))
        .route("/cancelswap", post(fuegod_post))
        .route("/requestswap", post(fuegod_post))
        .route("/getactiveswaps", post(fuegod_post))
        .route("/getswapstatus", post(fuegod_post))
        .route("/getinfo", post(fuegod_post))
        .layer(cors)
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(bind_addr).await.map_err(|e| format!("bind {}: {}", bind_addr, e))?;
    log::info!("fuego-wallet listening on {}", bind_addr);
    axum::serve(listener, app).await.map_err(|e| format!("server: {}", e))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use fuego_sdk::scanner::{HistoryDirection, HistoryEntry};

    #[test]
    fn query_parameters_become_typed_json_body() {
        let mut q = HashMap::new();
        q.insert("input_amount".to_string(), "5000000".to_string());
        q.insert("direction".to_string(), "1".to_string());
        q.insert("active_only".to_string(), "true".to_string());
        let body = query_to_body(&q);
        assert_eq!(body["input_amount"], json!(5000000u64));
        assert_eq!(body["direction"], json!(1u64));
        assert_eq!(body["active_only"], json!(true));
    }

    #[test]
    fn get_transactions_groups_by_block_in_walletd_shape() {
        let entry = |h: u64, dir, amount| HistoryEntry {
            tx_hash: [h as u8; 32],
            block_height: h,
            timestamp: 1_700_000_000 + h,
            direction: dir,
            amount,
            fee: 8000,
            heat_delta: 0,
            unlock_time: 0,
            payment_id: None,
        };
        let history = vec![
            entry(10, HistoryDirection::Incoming, 500),
            entry(10, HistoryDirection::Outgoing, 208),
            entry(12, HistoryDirection::Incoming, 7),
        ];
        let resp = walletd_transactions(&history, 12, &json!({})).unwrap();
        let v = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["items"].as_array().unwrap().len(), 2);
        let first = &v["items"][0]["transactions"];
        assert_eq!(first.as_array().unwrap().len(), 2);
        assert_eq!(first[1]["amount"], json!(-208));
        assert_eq!(first[0]["confirmations"], json!(3));
        assert!(first[0].get("transactionHash").is_some());
        let filtered = walletd_transactions(&history, 12, &json!({ "firstBlockIndex": 11 })).unwrap();
        assert_eq!(filtered.items.len(), 1);
    }

    #[test]
    fn json_rpc_only_methods_are_not_forwarded_as_http_paths() {
        assert!(rpc::is_json_rpc_method("getblockcount"));
        assert!(rpc::http_route("/getblockcount").is_none());
        assert_eq!(rpc::http_route("/amm_pool_info"), Some(Transport::Json));
        assert!(!rpc::is_json_rpc_method("amm_pool_info"));
    }
}
