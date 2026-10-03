use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::wallet_service::WalletService;
use crate::wallet_slot::WalletSlot;
use zeroize::Zeroize;

pub struct AppState {
    pub slot: Arc<WalletSlot>,
    pub fuegod_url: String,
}

/// Error for wallet methods called while no wallet is open (walletd started with
/// --await-wallet and the GUI has not sent open_wallet yet, or the vault is locked).
pub const NO_WALLET_OPEN: &str = "no wallet open";
const NO_WALLET_OPEN_CODE: i32 = -32001;

fn need(wallet: Option<&Mutex<WalletService>>) -> Result<&Mutex<WalletService>, String> {
    wallet.ok_or_else(|| NO_WALLET_OPEN.to_string())
}

#[derive(Serialize)]
struct JsonRpcSuccess {
    jsonrpc: String,
    id: u64,
    result: serde_json::Value,
}

#[derive(Serialize)]
struct JsonRpcError {
    jsonrpc: String,
    id: u64,
    error: RpcErrorDetail,
}

#[derive(Serialize)]
struct RpcErrorDetail {
    code: i32,
    message: String,
}

fn is_fuegod_method(method: &str) -> bool {
    matches!(method,
        "getinfo" | "getheight" | "getblockcount" | "on_getblockhash" | "getblock" |
        "getlastblockheader" | "getblockheaderbyhash" | "getblockheaderbyheight" |
        "peers" | "feeaddress" | "getethereal" | "paymentid" |
        "gettransactions" | "sendrawtransaction" |
        "getrandom_outs_json" | "get_outputs_heights" |
        "check_tx_proof" | "check_reserve_proof" |
        "start_mining" | "stop_mining" |
        "getcdoffers" | "submitcd" | "cancelcd" | "estimate_cd_yield" |
        "cd::market_list" | "cd::sell" | "cd::buy" | "cd::cancel_listing" | "cd::apy" |
        "heat_metrics" | "amm_quote" | "amm_pool_info" |
        "get_orderbook_state" | "get_orderbook_info" | "get_orderbook_estimates" |
        "get_fuego_price" | "getswapoffers" | "getswapprice" | "getswaptrades" |
        "submitswap" | "cancelswap" | "requestswap" |
        "getactiveswaps" | "getswapstatus" | "verify_payment" | "htlc_create_hash_lock" | "htlc_build_script" |
        "initiate" | "accept" | "processswap" | "refundswap" |
        "getdeposits" | "get_block_range" | "get_maturing_deposits" |
        "rollover_deposit" | "get_fee_pool_info" | "get_epoch_history" |
        "get_treasury_info" | "get_alias" | "get_alias_by_address" | "get_all_aliases" |
        "mint_heat" |
        "create_cd" | "withdraw_cd" | "create_deposit" | "withdraw_deposit"
    )
}

/// Returned by `handle_wallet_method` for names it does not implement, so the
/// dispatcher falls through to the fuegod proxy. The handler's match is the only
/// list of wallet methods; a separate allowlist had drifted and hid handlers.
const NOT_A_WALLET_METHOD: &str = "\u{0}not-a-wallet-method";

fn sanitize_error(msg: &str) -> String {
    if msg.contains("127.0.0.1") || msg.contains("localhost")
        || msg.contains("/Users/") || msg.contains("/home/")
        || msg.contains("http://") || msg.contains("https://") {
        return "internal error".to_string();
    }
    let sanitized = msg
        .trim_start_matches("HTTP: ")
        .trim_start_matches("JSON: ")
        .trim_start_matches("RPC: ")
        .to_string();
    sanitized
}

async fn proxy_to_fuegod(fuegod_url: &str, body: &serde_json::Value) -> Result<serde_json::Value, String> {
    let client = reqwest::Client::new();
    let method = body.get("method").and_then(|v| v.as_str()).unwrap_or("");
    let params = body.get("params").cloned().unwrap_or(serde_json::json!({}));

    let resp = match method {
        "getinfo" => {
            client.get(format!("{}/getinfo", fuegod_url)).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "getheight" => {
            client.post(format!("{}/getheight", fuegod_url))
                .json(&serde_json::json!({})).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "getblockcount" => {
            client.post(format!("{}/getblockcount", fuegod_url))
                .json(&serde_json::json!({})).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "on_getblockhash" => {
            client.post(format!("{}/on_getblockhash", fuegod_url))
                .json(&params).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "getblock" => {
            client.post(format!("{}/getblock", fuegod_url))
                .json(&params).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "getlastblockheader" => {
            client.post(format!("{}/getlastblockheader", fuegod_url))
                .json(&serde_json::json!({})).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "getblockheaderbyhash" => {
            client.post(format!("{}/getblockheaderbyhash", fuegod_url))
                .json(&params).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "getblockheaderbyheight" => {
            client.post(format!("{}/getblockheaderbyheight", fuegod_url))
                .json(&params).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "peers" => {
            client.post(format!("{}/peers", fuegod_url))
                .json(&serde_json::json!({})).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "feeaddress" => {
            client.post(format!("{}/feeaddress", fuegod_url))
                .json(&serde_json::json!({})).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "getethereal" => {
            client.post(format!("{}/getethereal", fuegod_url))
                .json(&serde_json::json!({})).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "paymentid" => {
            client.post(format!("{}/paymentid", fuegod_url))
                .json(&serde_json::json!({})).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "gettransactions" => {
            client.post(format!("{}/gettransactions", fuegod_url))
                .json(&params).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "sendrawtransaction" => {
            client.post(format!("{}/sendrawtransaction", fuegod_url))
                .json(&params).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "getrandom_outs_json" => {
            client.post(format!("{}/getrandom_outs_json", fuegod_url))
                .json(&params).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "get_outputs_heights" => {
            client.post(format!("{}/get_outputs_heights", fuegod_url))
                .json(&params).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "check_tx_proof" => {
            client.post(format!("{}/check_tx_proof", fuegod_url))
                .json(&params).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "check_reserve_proof" => {
            client.post(format!("{}/check_reserve_proof", fuegod_url))
                .json(&params).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "start_mining" => {
            client.post(format!("{}/start_mining", fuegod_url))
                .json(&params).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "stop_mining" => {
            client.post(format!("{}/stop_mining", fuegod_url))
                .json(&serde_json::json!({})).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        "getcdoffers" | "submitcd" | "cancelcd" | "estimate_cd_yield" |
        "cd::market_list" | "cd::sell" | "cd::buy" | "cd::cancel_listing" | "cd::apy" |
        "getswapoffers" | "getswapprice" | "getswaptrades" |
        "submitswap" | "cancelswap" | "requestswap" |
        "getactiveswaps" | "getswapstatus" | "verify_payment" | "htlc_create_hash_lock" | "htlc_build_script" |
        "initiate" | "accept" | "processswap" | "refundswap" |
        "getdeposits" | "get_block_range" | "get_maturing_deposits" |
        "rollover_deposit" | "get_fee_pool_info" | "get_epoch_history" |
        "get_treasury_info" | "get_alias" | "get_alias_by_address" | "get_all_aliases" |
        "heat_metrics" | "amm_quote" | "amm_pool_info" |
        "get_orderbook_info" | "get_orderbook_estimates" |
        "get_fuego_price" |
        "create_cd" | "withdraw_cd" | "create_deposit" | "withdraw_deposit" => {
            client.post(format!("{}/{}", fuegod_url, method))
                .json(&params).send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        // fuegod exposes the orderbook at /getorderbook (pair + depth);
        // the walletd method name is get_orderbook_state.
        "get_orderbook_state" => {
            let pair = params.get("pair").and_then(|v| v.as_u64()).unwrap_or(0);
            let depth = params.get("depth").and_then(|v| v.as_u64()).unwrap_or(20);
            client.post(format!("{}/getorderbook", fuegod_url))
                .json(&serde_json::json!({ "pair": pair, "depth": depth }))
                .send().await
                .map_err(|e| sanitize_error(&format!("fuego daemon: {}", e)))?
        }
        _ => {
            return Err(format!("unknown fuegod method: {}", method));
        }
    };

    let text = resp.text().await
        .map_err(|e| sanitize_error(&format!("fuego daemon response: {}", e)))?;
    let val: serde_json::Value = serde_json::from_str(&text)
        .unwrap_or_else(|_| serde_json::json!({"status": text.trim()}));
    Ok(val)
}

async fn handle_wallet_method(
    wallet: Option<&Mutex<WalletService>>,
    _fuegod_url: &str,
    method: &str,
    params: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    match method {
        "getBalance" | "getbalance" => {
            let wallet = need(wallet)?.lock().await;
            let balance = wallet.balance_full().await;
            Ok(serde_json::json!({
                "availableBalance": balance.confirmed,
                "lockedAmount": balance.pending + balance.immature,
                "blockCount": wallet.height().await,
            }))
        }
        "getAddress" | "getAddresses" | "get_address" => {
            let wallet = need(wallet)?.lock().await;
            Ok(serde_json::json!({
                "address": wallet.address().await,
            }))
        }
        "getHealth" => {
            let wallet = need(wallet)?.lock().await;
            let status = wallet.sync_status();
            Ok(serde_json::json!({
                "wallet": {
                    "ok": true,
                    "height": wallet.height().await,
                    "syncing": status.is_syncing,
                },
                "swap": {
                    "ok": crate::swapd::swapd_healthy(crate::swapd::SWAPD_RPC_PORT).await,
                },
            }))
        }
        "getStatus" | "get_height" => {
            let wallet = need(wallet)?.lock().await;
            let status = wallet.sync_status();
            Ok(serde_json::json!({
                "height": wallet.height().await,
                "target_height": status.target_height,
                "is_syncing": status.is_syncing,
            }))
        }
        "getTransactions" | "get_transfers" => {
            let wallet = need(wallet)?.lock().await;
            let txs = wallet.get_transactions(100).await;
            let items: Vec<serde_json::Value> = txs.iter().map(|tx| {
                serde_json::json!({
                    "transactionHash": hex::encode(tx.tx_hash),
                    "fee": tx.fee,
                    "blockIndex": tx.block_height,
                    "amount": match tx.direction {
                        fuego_sdk::scanner::HistoryDirection::Incoming => tx.amount as i64,
                        fuego_sdk::scanner::HistoryDirection::Outgoing => -(tx.amount as i64),
                    },
                    "transfers": [],
                })
            }).collect();
            Ok(serde_json::json!({ "items": items, "transactions": txs.len() }))
        }
        "sendTransaction" | "transfer" => {
            let destinations = params.get("destinations")
                .and_then(|d| d.as_array())
                .ok_or("missing destinations")?;
            let mut dests: Vec<(String, u64)> = Vec::with_capacity(destinations.len());
            for dest in destinations {
                let address = dest.get("address")
                    .and_then(|a| a.as_str())
                    .ok_or("missing address")?
                    .to_string();
                let amount = dest.get("amount")
                    .and_then(|a| a.as_u64())
                    .ok_or("missing amount")?;
                dests.push((address, amount));
            }
            if dests.is_empty() {
                return Err("empty destinations".into());
            }
            let fee = params.get("fee")
                .and_then(|f| f.as_u64())
                .unwrap_or(0);
            let anonymity = params.get("anonymity")
                .and_then(|a| a.as_u64())
                .unwrap_or(0) as u32;

            let wallet = need(wallet)?.lock().await;
            let tx_hash = wallet.send_transaction(&dests, fee, anonymity).await
                .map_err(|e| format!("send failed: {}", e))?;
            Ok(serde_json::json!({
                "transactionHash": tx_hash,
                "txHash": tx_hash,
            }))
        }
        "create_subaddress" => {
            let wallet = need(wallet)?.lock().await;
            let (index, address) = wallet.create_subaddress()?;
            Ok(serde_json::json!({ "index": index, "address": address }))
        }
        "get_subaddresses" => {
            let wallet = need(wallet)?.lock().await;
            let (subs, legacy) = wallet.list_subaddresses();
            Ok(serde_json::json!({
                "subaddresses": subs.iter().map(|(i, a, b)| serde_json::json!({
                    "index": i, "address": a, "balance": b,
                })).collect::<Vec<_>>(),
                "legacy": legacy.iter().map(|(i, b)| serde_json::json!({
                    "index": i, "balance": b,
                })).collect::<Vec<_>>(),
            }))
        }
        "register_legacy_subaddresses" => {
            let indices: Vec<u32> = params.get("indices")
                .and_then(|v| v.as_array())
                .ok_or("missing indices")?
                .iter()
                .map(|v| v.as_u64().filter(|n| *n >= 1 && *n < u32::MAX as u64).map(|n| n as u32)
                    .ok_or("indices must be integers in 1..u32::MAX"))
                .collect::<Result<_, _>>()?;
            let wallet = need(wallet)?.lock().await;
            let rescan = wallet.register_legacy_subaddresses(&indices);
            Ok(serde_json::json!({ "rescan": rescan }))
        }
        "sweep_legacy_subaddresses" => {
            let wallet = need(wallet)?.lock().await;
            let tx = wallet.sweep_legacy_subaddresses().await
                .map_err(|e| format!("sweep failed: {}", e))?;
            Ok(serde_json::json!({ "txHash": tx }))
        }
        "register_alias" => {
            let alias = params.get("alias")
                .and_then(|a| a.as_str())
                .ok_or("missing alias")?;
            let fee = params.get("fee")
                .and_then(|f| f.as_u64())
                .unwrap_or(100_000);
            let wallet = need(wallet)?.lock().await;
            let tx_hash = wallet.register_alias(alias, fee).await
                .map_err(|e| format!("alias registration failed: {}", e))?;
            Ok(serde_json::json!({
                "transactionHash": hex::encode(tx_hash),
                "txHash": hex::encode(tx_hash),
            }))
        }
        "create_integrated" => {
            let wallet = need(wallet)?.lock().await;
            let addr = wallet.address().await;
            Ok(serde_json::json!({
                "integratedAddress": addr,
            }))
        }
        "cd::config" | "get_cd_config" => {
            // Single source of truth for CD ladder tiers — GUI and AI agents
            // fetch this to build amount/term selection and ladder configs.
            Ok(serde_json::json!({
                "epoch_blocks": 900,
                "testnet_epoch_blocks": 10,
                "amount_tiers": [80000000, 10000000000_u64, 100000000000_u64, 1000000000000_u64, 10000000000000_u64],
                "amount_tiers_display": ["8", "1,000", "10,000", "100,000", "1M"],
                "term_tiers": [6, 18, 36, 72],
                "products": [
                    {"amount": 80000000, "term_epochs": 1,  "rollover": "AUTO",   "bonus_x": 1.00, "label": "Epoch-to-epoch (8 HEAT)"},
                    {"amount": null,     "term_epochs": 6,  "rollover": "MANUAL", "bonus_x": 1.25, "label": "6 epochs"},
                    {"amount": null,     "term_epochs": 18, "rollover": "MANUAL", "bonus_x": 1.50, "label": "18 epochs"},
                    {"amount": null,     "term_epochs": 36, "rollover": "MANUAL", "bonus_x": 2.00, "label": "36 epochs"},
                    {"amount": null,     "term_epochs": 72, "rollover": "MANUAL", "bonus_x": 2.50, "label": "72 epochs"}
                ],
                "rolling_term": 4294967294_u32,
                "deposit_min_amount": 80000000_u64,
                "deposit_min_term": 5400,
                "deposit_max_term": 64800,
                "ladder_example": {
                    "description": "Example 4-rung ladder: split 111,108 HEAT across 4 terms",
                    "rungs": [
                        {"amount": 10000000000_u64, "term_epochs": 6},
                        {"amount": 100000000000_u64, "term_epochs": 18},
                        {"amount": 1000000000000_u64, "term_epochs": 36},
                        {"amount": 10000000000000_u64, "term_epochs": 72}
                    ]
                }
            }))
        }
        // CD market / APY — proxied to daemon (is_fuegod_method). Kept as wallet
        // fallback only if daemon unavailable: return empty to keep GUI loadAll from failing.
        "cd::create_ladder" => {
            let ladder = params.get("rungs")
                .or_else(|| params.get("ladder"))
                .and_then(|v| v.as_array())
                .ok_or("missing rungs array")?;
            let mut tx_hashes = Vec::new();
            for rung in ladder {
                let amount = rung.get("amount")
                    .and_then(|a| a.as_u64())
                    .or_else(|| rung.get("amount").and_then(|a| a.as_str()).and_then(|s| s.parse().ok()))
                    .ok_or("rung missing amount")?;
                let term_epochs = rung.get("term_epochs")
                    .or_else(|| rung.get("term"))
                    .and_then(|v| v.as_u64())
                    .unwrap_or(6);
                let blocks = term_epochs * 900;
                let wallet = need(wallet)?.lock().await;
                let tx = wallet.create_cd(amount, blocks as u32).await
                    .map_err(|e| format!("ladder rung failed: {}", e))?;
                tx_hashes.push(tx);
            }
            Ok(serde_json::json!({"tx_hashes": tx_hashes, "created": tx_hashes.len()}))
        }
        "list_cds" | "cd::list" => {
            let wallet = need(wallet)?.lock().await;
            let cds = wallet.list_cds().await;
            Ok(serde_json::json!({
                "cds": cds,
            }))
        }
        "cd::create" | "create_cd" => {
            let amount = params.get("amount")
                .and_then(|a| a.as_u64())
                .or_else(|| params.get("amount").and_then(|a| a.as_str()).and_then(|s| s.parse().ok()))
                .ok_or("missing amount")?;
            let duration_blocks = params.get("duration_blocks")
                .and_then(|d| d.as_u64())
                .or_else(|| params.get("term").and_then(|d| d.as_u64()))
                .or_else(|| params.get("epochs").and_then(|d| d.as_u64()).map(|e| e * 900))
                .ok_or("missing duration_blocks")?;
            let wallet = need(wallet)?.lock().await;
            let tx_hash = wallet.create_cd(amount, duration_blocks as u32).await
                .map_err(|e| format!("create_cd failed: {}", e))?;
            let height = wallet.height().await;
            Ok(serde_json::json!({
                "cd_id": tx_hash,
                "tx_hash": tx_hash,
                "transactionHash": tx_hash,
                "txHash": tx_hash,
                "coin": "HEAT",
                "amount": (amount as f64 / 10_000_000.0).to_string(),
                "maturity_at": (height + duration_blocks).to_string(),
            }))
        }
        "cd::claim" | "claim_cd" => {
            let cd_id = params.get("cd_id")
                .and_then(|a| a.as_str())
                .unwrap_or("")
                .to_string();
            let wallet = need(wallet)?.lock().await;
            let tx_hash = wallet.claim_cd().await
                .map_err(|e| format!("claim_cd failed: {}", e))?;
            Ok(serde_json::json!({
                "cd_id": cd_id,
                "tx_hash": tx_hash,
                "transactionHash": tx_hash,
                "txHash": tx_hash,
                "coin": "HEAT",
                "principal": "0",
                "interest": "0",
                "total": "0",
            }))
        }
        "rollover_cd" | "cd::rollover" => {
            let cd_id = params.get("cd_id")
                .and_then(|a| a.as_str())
                .or_else(|| params.get("deposit_id").and_then(|a| a.as_str()))
                .ok_or("missing cd_id")?
                .to_string();
            let new_term = params.get("new_term")
                .and_then(|a| a.as_u64())
                .or_else(|| params.get("term").and_then(|a| a.as_u64()))
                .unwrap_or(0) as u32;
            let wallet = need(wallet)?.lock().await;
            let tx_hash = wallet.rollover_cd(&cd_id, new_term).await
                .map_err(|e| format!("rollover_cd failed: {}", e))?;
            Ok(serde_json::json!({
                "cd_id": cd_id,
                "tx_hash": tx_hash,
                "transactionHash": tx_hash,
                "txHash": tx_hash,
                "coin": "HEAT",
                "status": "OK",
            }))
        }
        "create_afk_lock" => {
            let amount = params.get("amount")
                .and_then(|a| a.as_u64())
                .ok_or("missing amount")?;
            let timeout_hours = params.get("timeout_hours")
                .and_then(|t| t.as_u64())
                .ok_or("missing timeout_hours")?;
            let pair = params.get("pair")
                .and_then(|p| p.as_u64())
                .unwrap_or(0);
            let wallet = need(wallet)?.lock().await;
            let (lock_id, adaptor_point, pre_sig, hash_lock) =
                wallet.create_afk_lock(amount, timeout_hours as u32, pair as u8).await
                    .map_err(|e| format!("create_afk_lock failed: {}", e))?;
            Ok(serde_json::json!({
                "lockId": lock_id,
                "adaptorPoint": adaptor_point,
                "preSig": pre_sig,
                "hashLock": hash_lock,
            }))
        }
        "send_heat" => {
            let address = params.get("address")
                .and_then(|a| a.as_str())
                .ok_or("missing address")?;
            let amount = params.get("amount")
                .and_then(|a| a.as_u64())
                .ok_or("missing amount")?;
            let wallet = need(wallet)?.lock().await;
            let tx_hash = wallet.send_heat(address, amount).await
                .map_err(|e| format!("send_heat failed: {}", e))?;
            Ok(serde_json::json!({
                "transactionHash": tx_hash,
                "txHash": tx_hash,
            }))
        }
        "get_tx_proof" | "getTxProof" => {
            let tx_hash = params.get("tx_hash")
                .and_then(|t| t.as_str())
                .or_else(|| params.get("txid").and_then(|t| t.as_str()))
                .ok_or("missing tx_hash")?;
            let address = params.get("address")
                .and_then(|a| a.as_str())
                .ok_or("missing address")?;
            let wallet = need(wallet)?.lock().await;
            let proof = wallet.get_tx_proof(tx_hash, address).await
                .map_err(|e| format!("get_tx_proof failed: {}", e))?;
            Ok(serde_json::json!({ "signature": proof }))
        }
        "mint_heat" => {
            let xfg_burned = params.get("xfg_burned")
                .and_then(|a| a.as_u64())
                .or_else(|| params.get("amount").and_then(|a| a.as_u64()))
                .ok_or("missing xfg_burned")?;
            let wallet = need(wallet)?.lock().await;
            let tx_hash = wallet.mint_heat(xfg_burned).await
                .map_err(|e| format!("mint_heat failed: {}", e))?;
            Ok(serde_json::json!({
                "transactionHash": tx_hash,
                "txHash": tx_hash,
            }))
        }
        "swap" => {
            let direction_raw = params.get("direction")
                .and_then(|d| d.as_str())
                .unwrap_or("");
            let direction = match direction_raw {
                "heat_to_xfg" | "1" => 1u8,
                _ => 0u8,
            };
            let input_amount = params.get("input_amount")
                .and_then(|v| v.as_str())
                .and_then(|s| s.parse::<u64>().ok())
                .or_else(|| params.get("input_amount").and_then(|v| v.as_u64()))
                .ok_or("missing input_amount")?;
            let min_output = params.get("min_output")
                .and_then(|v| v.as_str())
                .and_then(|s| s.parse::<u64>().ok())
                .or_else(|| params.get("min_output").and_then(|v| v.as_u64()))
                .unwrap_or(0);
            let wallet = need(wallet)?.lock().await;
            let tx_hash = wallet.amm_swap(direction, input_amount, min_output).await
                .map_err(|e| format!("swap failed: {}", e))?;
            Ok(serde_json::json!({
                "transactionHash": tx_hash,
                "txHash": tx_hash,
            }))
        }
        "add_liq" => {
            let xfg_amount = params.get("xfg_amount")
                .and_then(|v| v.as_str())
                .and_then(|s| s.parse::<u64>().ok())
                .or_else(|| params.get("xfg_amount").and_then(|v| v.as_u64()))
                .ok_or("missing xfg_amount")?;
            let heat_amount = params.get("heat_amount")
                .and_then(|v| v.as_str())
                .and_then(|s| s.parse::<u64>().ok())
                .or_else(|| params.get("heat_amount").and_then(|v| v.as_u64()))
                .ok_or("missing heat_amount")?;
            let wallet = need(wallet)?.lock().await;
            let tx_hash = wallet.lp_add(xfg_amount, heat_amount).await
                .map_err(|e| format!("add_liq failed: {}", e))?;
            Ok(serde_json::json!({
                "transactionHash": tx_hash,
                "txHash": tx_hash,
            }))
        }
        "remove_liq" => {
            let shares = params.get("shares")
                .and_then(|v| v.as_str())
                .and_then(|s| s.parse::<u64>().ok())
                .or_else(|| params.get("shares").and_then(|v| v.as_u64()))
                .ok_or("missing shares")?;
            let min_xfg = params.get("min_xfg")
                .and_then(|v| v.as_str())
                .and_then(|s| s.parse::<u64>().ok())
                .or_else(|| params.get("min_xfg").and_then(|v| v.as_u64()))
                .unwrap_or(0);
            let min_heat = params.get("min_heat")
                .and_then(|v| v.as_str())
                .and_then(|s| s.parse::<u64>().ok())
                .or_else(|| params.get("min_heat").and_then(|v| v.as_u64()))
                .unwrap_or(0);
            let wallet = need(wallet)?.lock().await;
            let tx_hash = wallet.lp_remove(shares, min_xfg, min_heat).await
                .map_err(|e| format!("remove_liq failed: {}", e))?;
            Ok(serde_json::json!({
                "transactionHash": tx_hash,
                "txHash": tx_hash,
            }))
        }
        "place_limit_order" => {
            let side_raw = params.get("side").and_then(|s| s.as_str()).unwrap_or("sell");
            let side = match side_raw {
                "buy" | "0" => 0u8,
                _ => 1u8,
            };
            let amount = params.get("amount")
                .and_then(|v| v.as_str())
                .and_then(|s| s.parse::<u64>().ok())
                .or_else(|| params.get("amount").and_then(|v| v.as_u64()))
                .ok_or("missing amount")?;
            // price arrives as a human HEAT-per-XFG decimal; convert to
            // chain atomics (price * COIN) like spot_price scaling.
            let price_atomic = params.get("price")
                .and_then(|v| v.as_str())
                .and_then(|s| s.parse::<f64>().ok().map(|p| (p * 10_000_000f64).round() as u64))
                .or_else(|| params.get("price").and_then(|v| v.as_u64()))
                .ok_or("missing price")?;
            let expiration = params.get("ttlBlocks")
                .and_then(|v| v.as_u64())
                .or_else(|| params.get("expiration").and_then(|v| v.as_u64()))
                .unwrap_or(8640) as u32;
            let wallet = need(wallet)?.lock().await;
            let tx_hash = wallet.place_limit_order(side, amount, price_atomic, expiration).await
                .map_err(|e| format!("place_limit_order failed: {}", e))?;
            Ok(serde_json::json!({
                "transactionHash": tx_hash,
                "txHash": tx_hash,
            }))
        }
        "heat_cd" => {
            let amount = params.get("amount")
                .and_then(|a| a.as_u64())
                .ok_or("missing amount")?;
            let epochs = params.get("epochs")
                .and_then(|e| e.as_u64())
                .ok_or("missing epochs")?;
            let banking_fee = params.get("banking_fee")
                .and_then(|f| f.as_u64())
                .unwrap_or(0);
            let wallet = need(wallet)?.lock().await;
            let tx_hash = wallet.heat_cd(amount, epochs as u32, banking_fee).await
                .map_err(|e| format!("heat_cd failed: {}", e))?;
            Ok(serde_json::json!({
                "transactionHash": tx_hash,
                "txHash": tx_hash,
            }))
        }
        _ => Err(NOT_A_WALLET_METHOD.to_string()),
    }
}

fn is_authorized_host(headers: &axum::http::HeaderMap) -> bool {
    if let Some(host_val) = headers.get(axum::http::header::HOST) {
        if let Ok(host_str) = host_val.to_str() {
            let host_clean = host_str.split(':').next().unwrap_or("").to_lowercase();
            if host_clean == "localhost" || host_clean == "127.0.0.1" || host_clean == "[::1]" || host_clean.is_empty() {
                return true;
            }
        }
        false
    } else {
        true
    }
}

/// Decode a 32-byte hex seed, wiping the intermediate buffer.
fn decode_seed(hex_str: &str) -> Result<[u8; 32], String> {
    let mut seed = [0u8; 32];
    if hex::decode_to_slice(hex_str.trim().trim_start_matches("0x"), &mut seed).is_err() {
        seed.zeroize();
        return Err("seed must be 32 bytes of hex".into());
    }
    Ok(seed)
}

/// Methods that manage which wallet is open. `None`: not one of them.
async fn handle_slot_method(
    slot: &WalletSlot,
    method: &str,
    body: &mut serde_json::Value,
) -> Option<Result<serde_json::Value, String>> {
    let result = match method {
        "open_wallet" => {
            // Take the seed out of the request and wipe the copy it held.
            let mut hex_seed = match body.pointer_mut("/params/seed") {
                Some(serde_json::Value::String(s)) => std::mem::take(s),
                _ => String::new(),
            };
            let seed = decode_seed(&hex_seed);
            hex_seed.zeroize();
            match seed {
                Err(e) => Err(e),
                Ok(seed) => match slot.open(seed).await {
                    Err(e) => Err(e),
                    Ok(id) => {
                        let address = match slot.current().await {
                            Some(w) => w.lock().await.primary_address_string(),
                            None => String::new(),
                        };
                        Ok(serde_json::json!({ "id": id, "address": address }))
                    }
                },
            }
        }
        "close_wallet" => Ok(serde_json::json!({ "closed": slot.close().await })),
        "wallet_status" => Ok(match slot.current().await {
            Some(w) => {
                let w = w.lock().await;
                serde_json::json!({ "open": true, "id": w.id(), "address": w.primary_address_string() })
            }
            None => serde_json::json!({ "open": false }),
        }),
        "get_legacy_wallet" => Ok(match slot.legacy().await {
            Some(w) => {
                let w = w.lock().await;
                let balance = w.balance_full().await;
                let status = w.sync_status();
                serde_json::json!({
                    "address": w.primary_address_string(),
                    "balance": balance.confirmed,
                    "pending": balance.pending + balance.immature,
                    "height": status.current_height,
                    "targetHeight": status.target_height,
                    "syncing": status.is_syncing,
                })
            }
            None => serde_json::Value::Null,
        }),
        "sweep_legacy_wallet" => match (slot.legacy().await, slot.current().await) {
            (None, _) => Err("no legacy wallet".into()),
            (_, None) => Err(NO_WALLET_OPEN.into()),
            (Some(legacy), Some(open)) => {
                let to = open.lock().await.primary_address_string();
                let legacy = legacy.lock().await;
                legacy
                    .sweep_all_to(&to)
                    .await
                    .map(|(tx, remaining)| serde_json::json!({ "txHash": tx, "remaining": remaining }))
            }
        },
        _ => return None,
    };
    Some(result)
}

fn rpc_error(id: u64, code: i32, message: String) -> axum::response::Response {
    let error = JsonRpcError { jsonrpc: "2.0".into(), id, error: RpcErrorDetail { code, message } };
    (StatusCode::OK, Json(serde_json::to_value(error).unwrap())).into_response()
}

async fn json_rpc_handler(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    Json(mut body): Json<serde_json::Value>,
) -> impl IntoResponse {
    let id = body.get("id").and_then(|v| v.as_u64()).unwrap_or(0);
    let method = body.get("method").and_then(|v| v.as_str()).unwrap_or("").to_string();

    if !is_authorized_host(&headers) {
        let error = JsonRpcError {
            jsonrpc: "2.0".into(), id,
            error: RpcErrorDetail { code: -32500, message: "forbidden host".into() },
        };
        return (StatusCode::FORBIDDEN, Json(serde_json::to_value(error).unwrap())).into_response();
    }

    let result: Result<serde_json::Value, String> =
        match handle_slot_method(&state.slot, &method, &mut body).await {
            Some(r) => r,
            None => {
                let params = body.get("params").cloned().unwrap_or(serde_json::Value::Null);
                let wallet = state.slot.current().await;
                match handle_wallet_method(wallet.as_deref(), &state.fuegod_url, &method, &params).await {
                    Err(e) if e == NOT_A_WALLET_METHOD => {
                        if is_fuegod_method(&method) {
                            proxy_to_fuegod(&state.fuegod_url, &body).await
                        } else {
                            Err(format!("unknown method: {}", method))
                        }
                    }
                    other => other,
                }
            }
        };

    match result {
        Ok(val) => {
            let success = JsonRpcSuccess { jsonrpc: "2.0".into(), id, result: val };
            (StatusCode::OK, Json(serde_json::to_value(success).unwrap())).into_response()
        }
        Err(msg) if msg == NO_WALLET_OPEN => rpc_error(id, NO_WALLET_OPEN_CODE, msg),
        Err(msg) => rpc_error(id, -32000, msg),
    }
}

// ── REST proxy: forward requests to fuegod ──

async fn fuegod_get(
    State(state): State<Arc<AppState>>,
    req: axum::http::Request<axum::body::Body>,
) -> impl IntoResponse {
    if !is_authorized_host(req.headers()) {
        return (StatusCode::FORBIDDEN, Json(serde_json::json!({"error": "forbidden host"}))).into_response();
    }
    let fuegod_path = req.uri().path();
    let fuegod_query = req.uri().query().unwrap_or("");
    let client = reqwest::Client::new();
    let url = if fuegod_query.is_empty() {
        format!("{}{}", state.fuegod_url, fuegod_path)
    } else {
        format!("{}{}?{}", state.fuegod_url, fuegod_path, fuegod_query)
    };
    
    match client.get(&url).send().await {
        Ok(r) => {
            let status = StatusCode::from_u16(r.status().as_u16()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
            match r.text().await {
                Ok(text) => {
                    let val: serde_json::Value = serde_json::from_str(&text)
                        .unwrap_or_else(|_| serde_json::json!({"raw": text}));
                    (status, Json(val)).into_response()
                }
                Err(_) => (StatusCode::BAD_GATEWAY, Json(serde_json::json!({"error": "failed to read response"}))).into_response()
            }
        }
        Err(e) => (StatusCode::BAD_GATEWAY, Json(serde_json::json!({"error": sanitize_error(&e.to_string())}))).into_response()
    }
}

async fn fuegod_post(
    State(state): State<Arc<AppState>>,
    req: axum::http::Request<axum::body::Body>,
) -> impl IntoResponse {
    if !is_authorized_host(req.headers()) {
        return (StatusCode::FORBIDDEN, Json(serde_json::json!({"error": "forbidden host"}))).into_response();
    }
    let fuegod_path = req.uri().path().to_string();
    let (parts, body) = req.into_parts();
    let _ = parts;
    let body_bytes = axum::body::to_bytes(body, usize::MAX).await.unwrap_or_default();
    let body: serde_json::Value = serde_json::from_slice(&body_bytes).unwrap_or(serde_json::json!({}));
    let client = reqwest::Client::new();
    let url = format!("{}{}", state.fuegod_url, fuegod_path);
    
    match client.post(&url).json(&body).send().await {
        Ok(r) => {
            let status = StatusCode::from_u16(r.status().as_u16()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
            match r.text().await {
                Ok(text) => {
                    let val: serde_json::Value = serde_json::from_str(&text)
                        .unwrap_or_else(|_| serde_json::json!({"raw": text}));
                    (status, Json(val)).into_response()
                }
                Err(_) => (StatusCode::BAD_GATEWAY, Json(serde_json::json!({"error": "failed to read response"}))).into_response()
            }
        }
        Err(e) => (StatusCode::BAD_GATEWAY, Json(serde_json::json!({"error": sanitize_error(&e.to_string())}))).into_response()
    }
}

// ── Status endpoint (wallet state) ──

fn forbidden() -> axum::response::Response {
    (StatusCode::FORBIDDEN, Json(serde_json::json!({"error": "forbidden host"}))).into_response()
}

fn no_wallet() -> axum::response::Response {
    (StatusCode::CONFLICT, Json(serde_json::json!({"error": NO_WALLET_OPEN}))).into_response()
}

async fn status_handler(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
) -> axum::response::Response {
    if !is_authorized_host(&headers) {
        return forbidden();
    }
    let Some(wallet) = state.slot.current().await else { return no_wallet() };
    let wallet = wallet.lock().await;
    let balance = wallet.balance_full().await;
    let status = wallet.sync_status();
    Json(serde_json::json!({
        "address": wallet.address().await,
        "balance": balance.confirmed,
        "pending": balance.pending,
        "immature": balance.immature,
        "height": wallet.height().await,
        "target_height": status.target_height,
        "is_syncing": status.is_syncing,
    }))
    .into_response()
}

async fn health_check(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
) -> axum::response::Response {
    if !is_authorized_host(&headers) {
        return forbidden();
    }
    let client = reqwest::Client::new();
    let fuegod_ok = client.get(format!("{}/getinfo", state.fuegod_url))
        .send().await
        .map(|r| r.status().is_success())
        .unwrap_or(false);

    let (wallet_json, scanned) = match state.slot.current().await {
        Some(wallet) => {
            let wallet = wallet.lock().await;
            let status = wallet.sync_status();
            (
                serde_json::json!({
                    "address": wallet.address().await,
                    "balance": wallet.balance().await,
                    "height": status.current_height,
                    "syncing": status.is_syncing,
                }),
                serde_json::json!(wallet.height().await),
            )
        }
        None => (serde_json::Value::Null, serde_json::Value::Null),
    };

    Json(serde_json::json!({
        "status": if fuegod_ok { "ok" } else { "degraded" },
        "fuego": fuegod_ok,
        "daemon": fuegod_ok,
        "swap": crate::swapd::swapd_healthy(crate::swapd::SWAPD_RPC_PORT).await,
        "wallet": wallet_json,
        "scanned_height": scanned,
    }))
    .into_response()
}

#[derive(Deserialize)]
struct ScanBalanceRequest {
    view_secret: String,
    spend_public: String,
}

/// Balance of the open wallet. The caller's keys must be that wallet's: this is how
/// the GUI confirms walletd is serving the unlocked vault and not some other wallet.
async fn scan_balance_handler(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    Json(mut req): Json<ScanBalanceRequest>,
) -> axum::response::Response {
    if !is_authorized_host(&headers) {
        req.view_secret.zeroize();
        return forbidden();
    }
    let Some(wallet) = state.slot.current().await else {
        req.view_secret.zeroize();
        return no_wallet();
    };
    let wallet = wallet.lock().await;
    let matches = wallet.has_keys(&req.view_secret, &req.spend_public);
    req.view_secret.zeroize();
    if !matches {
        return (
            StatusCode::CONFLICT,
            Json(serde_json::json!({"error": "open wallet does not match these keys"})),
        )
            .into_response();
    }
    let balance = wallet.balance_full().await;
    let status = wallet.sync_status();
    Json(serde_json::json!({
        "balance": balance.confirmed,
        "pending": balance.pending,
        "immature": balance.immature,
        "height": status.current_height,
        "address": wallet.address().await,
    }))
    .into_response()
}

pub async fn run_server(
    slot: Arc<WalletSlot>,
    fuegod_url: &str,
    bind_addr: &str,
) -> Result<(), String> {
    let state = Arc::new(AppState {
        slot,
        fuegod_url: fuegod_url.to_string(),
    });

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
        // HEARTH AMM REST proxy
        .route("/amm_pool_info", get(fuegod_get))
        .route("/amm_quote", get(fuegod_get))
        .route("/heat_metrics", get(fuegod_get))
        .route("/get_fuego_price", get(fuegod_get))
        // Orderbook REST proxy
        .route("/get_orderbook_state", get(fuegod_get))
        .route("/getorderbook", get(fuegod_get))
        .route("/get_orderbook_info", get(fuegod_get))
        .route("/get_orderbook_estimates", get(fuegod_get))
        // DEX/swap REST proxy (GET)
        .route("/getswapoffers", get(fuegod_get))
        .route("/getswapprice", get(fuegod_get))
        .route("/getswaptrades", get(fuegod_get))
        .route("/getswaprequests", get(fuegod_get))
        // DEX/swap REST proxy (POST)
        .route("/submitswap", post(fuegod_post))
        .route("/cancelswap", post(fuegod_post))
        .route("/requestswap", post(fuegod_post))
        .route("/getactiveswaps", post(fuegod_post))
        .route("/getswapstatus", post(fuegod_post))
        .route("/verify_payment", post(fuegod_post))
        .route("/htlc_create_hash_lock", post(fuegod_post))
        .route("/htlc_build_script", post(fuegod_post))
        // Extra robustness GET endpoints
        .route("/getactiveswaps", get(fuegod_get))
        .route("/getswapstatus", get(fuegod_get))
        .route("/getinfo", get(fuegod_get))
        .route("/getinfo", post(fuegod_post))
        .layer(cors)
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(bind_addr).await
        .map_err(|e| format!("bind {}: {}", bind_addr, e))?;

    log::info!("fuego-wallet listening on {}", bind_addr);

    axum::serve(listener, app).await
        .map_err(|e| format!("server: {}", e))?;

    Ok(())
}

#[cfg(test)]
mod dispatch_tests {
    use super::*;

    async fn call(wallet: &Mutex<WalletService>, method: &str, params: serde_json::Value) -> Result<serde_json::Value, String> {
        handle_wallet_method(Some(wallet), "http://127.0.0.1:1", method, &params).await
    }

    #[tokio::test]
    async fn without_an_open_wallet_only_wallet_methods_are_refused() {
        let params = serde_json::json!({});
        let rpc = |m: &'static str| handle_wallet_method(None, "http://127.0.0.1:1", m, &params);
        for m in ["getBalance", "getAddress", "create_subaddress", "sweep_legacy_subaddresses"] {
            assert_eq!(rpc(m).await.unwrap_err(), NO_WALLET_OPEN, "{m}");
        }
        // Wallet methods that share a name with a fuegod endpoint never fall through to it.
        for m in ["create_cd", "mint_heat", "sendTransaction"] {
            assert_ne!(rpc(m).await.unwrap_err(), NOT_A_WALLET_METHOD, "{m}");
        }
        // Chain methods still reach fuegod.
        assert_eq!(rpc("getinfo").await.unwrap_err(), NOT_A_WALLET_METHOD);
    }

    #[tokio::test]
    async fn slot_methods_open_and_close_the_wallet() {
        let root = std::env::temp_dir().join(format!("fuego-slotrpc-{}", std::process::id()));
        let slot = WalletSlot::new(root.clone(), "http://127.0.0.1:1", false);
        let seed_hex = hex::encode([6u8; 32]);
        let mut body = serde_json::json!({"method": "open_wallet", "params": {"seed": seed_hex}});

        let opened = handle_slot_method(&slot, "open_wallet", &mut body).await.unwrap().unwrap();
        assert_eq!(body["params"]["seed"], "", "seed wiped from the request");
        let status = handle_slot_method(&slot, "wallet_status", &mut serde_json::json!({})).await.unwrap().unwrap();
        assert_eq!(status["open"], true);
        assert_eq!(status["address"], opened["address"]);

        let mut bad = serde_json::json!({"params": {"seed": "abcd"}});
        assert!(handle_slot_method(&slot, "open_wallet", &mut bad).await.unwrap().is_err());

        let closed = handle_slot_method(&slot, "close_wallet", &mut serde_json::json!({})).await.unwrap().unwrap();
        assert_eq!(closed["closed"], true);
        assert!(slot.current().await.is_none());
        assert!(handle_slot_method(&slot, "get_legacy_wallet", &mut serde_json::json!({})).await.unwrap().unwrap().is_null());
        assert!(handle_slot_method(&slot, "getBalance", &mut serde_json::json!({})).await.is_none());
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn subaddress_methods_reach_the_wallet() {
        let dir = std::env::temp_dir().join(format!("fuego-dispatch-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let svc = WalletService::new([5u8; 32], "http://127.0.0.1:1", dir.clone(), false).unwrap();
        let wallet = Mutex::new(svc);

        let created = call(&wallet, "create_subaddress", serde_json::json!({})).await.unwrap();
        assert_eq!(created["index"], 1);
        let listed = call(&wallet, "get_subaddresses", serde_json::json!({})).await.unwrap();
        assert_eq!(listed["subaddresses"][0]["address"], created["address"]);
        let reg = call(&wallet, "register_legacy_subaddresses", serde_json::json!({"indices": [1]})).await.unwrap();
        assert_eq!(reg["rescan"], true);
        // No confirmed legacy outputs: nothing to sweep, and no daemon call is made.
        let swept = call(&wallet, "sweep_legacy_subaddresses", serde_json::json!({})).await.unwrap();
        assert!(swept["txHash"].is_null());

        // Names the handler does not implement fall through to the fuegod proxy.
        assert_eq!(call(&wallet, "getinfo", serde_json::json!({})).await.unwrap_err(), NOT_A_WALLET_METHOD);
        let _ = std::fs::remove_dir_all(dir);
    }
}
