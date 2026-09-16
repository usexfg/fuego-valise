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

pub struct AppState {
    pub wallet: Arc<Mutex<WalletService>>,
    pub fuegod_url: String,
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

fn is_wallet_method(method: &str) -> bool {
    matches!(method,
        "getBalance" | "getAddresses" | "getAddress" | "getTransactions" |
        "sendTransaction" | "getStatus" | "register_alias" | "create_cd" | "claim_cd" |
        "create_integrated" | "list_cds" | "cd::list" | "cd::create" | "cd::claim" |
        "rollover_cd" | "cd::rollover" | "cd::config" | "get_cd_config" |
        "cd::create_ladder" | "create_ladder" |
        "mint_heat" | "swap" | "add_liq" | "remove_liq" | "place_limit_order"
    )
}

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
    wallet: &Mutex<WalletService>,
    _fuegod_url: &str,
    method: &str,
    params: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    match method {
        "getBalance" | "getbalance" => {
            let wallet = wallet.lock().await;
            let balance = wallet.balance_full().await;
            Ok(serde_json::json!({
                "availableBalance": balance.confirmed,
                "lockedAmount": balance.pending + balance.immature,
                "blockCount": wallet.height().await,
            }))
        }
        "getAddress" | "getAddresses" | "get_address" => {
            let wallet = wallet.lock().await;
            Ok(serde_json::json!({
                "address": wallet.address().await,
            }))
        }
        "getHealth" => {
            let wallet = wallet.lock().await;
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
            let wallet = wallet.lock().await;
            let status = wallet.sync_status();
            Ok(serde_json::json!({
                "height": wallet.height().await,
                "target_height": status.target_height,
                "is_syncing": status.is_syncing,
            }))
        }
        "getTransactions" | "get_transfers" => {
            let wallet = wallet.lock().await;
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

            let wallet = wallet.lock().await;
            let tx_hash = wallet.send_transaction(&dests, fee, anonymity).await
                .map_err(|e| format!("send failed: {}", e))?;
            Ok(serde_json::json!({
                "transactionHash": tx_hash,
                "txHash": tx_hash,
            }))
        }
        "register_alias" => {
            let alias = params.get("alias")
                .and_then(|a| a.as_str())
                .ok_or("missing alias")?;
            let fee = params.get("fee")
                .and_then(|f| f.as_u64())
                .unwrap_or(100_000);
            let wallet = wallet.lock().await;
            let tx_hash = wallet.register_alias(alias, fee).await
                .map_err(|e| format!("alias registration failed: {}", e))?;
            Ok(serde_json::json!({
                "transactionHash": hex::encode(tx_hash),
                "txHash": hex::encode(tx_hash),
            }))
        }
        "create_integrated" => {
            let wallet = wallet.lock().await;
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
        "cd::apy" | "estimate_cd_yield" => {
            Ok(serde_json::json!({
                "coin": "HEAT",
                "current_apy": 0.0,
                "average_apy": 0.0,
                "epoch": 0
            }))
        }
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
                let wallet = wallet.lock().await;
                let tx = wallet.create_cd(amount, blocks as u32).await
                    .map_err(|e| format!("ladder rung failed: {}", e))?;
                tx_hashes.push(tx);
            }
            Ok(serde_json::json!({"tx_hashes": tx_hashes, "created": tx_hashes.len()}))
        }
        "list_cds" | "cd::list" => {
            let wallet = wallet.lock().await;
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
            let wallet = wallet.lock().await;
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
            let wallet = wallet.lock().await;
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
            let wallet = wallet.lock().await;
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
            let wallet = wallet.lock().await;
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
            let wallet = wallet.lock().await;
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
            let wallet = wallet.lock().await;
            let proof = wallet.get_tx_proof(tx_hash, address).await
                .map_err(|e| format!("get_tx_proof failed: {}", e))?;
            Ok(serde_json::json!({ "signature": proof }))
        }
        "mint_heat" => {
            let xfg_burned = params.get("xfg_burned")
                .and_then(|a| a.as_u64())
                .or_else(|| params.get("amount").and_then(|a| a.as_u64()))
                .ok_or("missing xfg_burned")?;
            let wallet = wallet.lock().await;
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
            let wallet = wallet.lock().await;
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
            let wallet = wallet.lock().await;
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
            let wallet = wallet.lock().await;
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
                .and_then(|s| (s.parse::<f64>().ok().map(|p| (p * 10_000_000f64).round() as u64)))
                .or_else(|| params.get("price").and_then(|v| v.as_u64()))
                .ok_or("missing price")?;
            let expiration = params.get("ttlBlocks")
                .and_then(|v| v.as_u64())
                .or_else(|| params.get("expiration").and_then(|v| v.as_u64()))
                .unwrap_or(8640) as u32;
            let wallet = wallet.lock().await;
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
            let wallet = wallet.lock().await;
            let tx_hash = wallet.heat_cd(amount, epochs as u32, banking_fee).await
                .map_err(|e| format!("heat_cd failed: {}", e))?;
            Ok(serde_json::json!({
                "transactionHash": tx_hash,
                "txHash": tx_hash,
            }))
        }
        _ => Err(format!("unknown wallet method: {}", method)),
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

async fn json_rpc_handler(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    Json(body): Json<serde_json::Value>,
) -> impl IntoResponse {
    let id = body.get("id").and_then(|v| v.as_u64()).unwrap_or(0);
    let method = body.get("method").and_then(|v| v.as_str()).unwrap_or("");

    if !is_authorized_host(&headers) {
        let error = JsonRpcError {
            jsonrpc: "2.0".into(), id,
            error: RpcErrorDetail { code: -32500, message: "forbidden host".into() },
        };
        return (StatusCode::FORBIDDEN, Json(serde_json::to_value(error).unwrap())).into_response();
    }

    let result: Result<serde_json::Value, String> = if is_wallet_method(method) {
        let params = body.get("params").cloned().unwrap_or(serde_json::Value::Null);
        handle_wallet_method(&state.wallet, &state.fuegod_url, method, &params).await
    } else if is_fuegod_method(method) {
        proxy_to_fuegod(&state.fuegod_url, &body).await
    } else {
        Err(format!("unknown method: {}", method))
    };

    match result {
        Ok(val) => {
            let success = JsonRpcSuccess { jsonrpc: "2.0".into(), id, result: val };
            (StatusCode::OK, Json(serde_json::to_value(success).unwrap())).into_response()
        }
        Err(msg) => {
            let error = JsonRpcError {
                jsonrpc: "2.0".into(), id,
                error: RpcErrorDetail { code: -32000, message: msg },
            };
            (StatusCode::OK, Json(serde_json::to_value(error).unwrap())).into_response()
        }
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

async fn status_handler(
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let wallet = state.wallet.lock().await;
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
}

async fn health_check(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let client = reqwest::Client::new();
    let fuegod_ok = client.get(format!("{}/getinfo", state.fuegod_url))
        .send().await
        .map(|r| r.status().is_success())
        .unwrap_or(false);

    let wallet = state.wallet.lock().await;
    let status = wallet.sync_status();

    Json(serde_json::json!({
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
        "scanned_height": wallet.height().await,
    }))
}

#[derive(Deserialize)]
struct ScanBalanceRequest {
    view_secret: String,
    spend_public: String,
    #[serde(default)]
    start_height: u64,
    #[serde(default = "default_batch_size")]
    batch_size: u64,
}

fn default_batch_size() -> u64 { 100 }

async fn scan_balance_handler(
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let wallet = state.wallet.lock().await;
    let balance = wallet.balance_full().await;
    let status = wallet.sync_status();
    Json(serde_json::json!({
        "balance": balance.confirmed,
        "pending": balance.pending,
        "immature": balance.immature,
        "height": status.current_height,
        "address": wallet.address().await,
    }))
}

pub async fn run_server(
    wallet: Arc<Mutex<WalletService>>,
    fuegod_url: &str,
    bind_addr: &str,
) -> Result<(), String> {
    let state = Arc::new(AppState {
        wallet,
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
