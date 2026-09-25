// Drift check: the SDK's `.bin` builders/parsers against a real fuegod (see AGENTS.md).

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

use fuego_sdk::serialization::{
    get_o_indexes_request, get_random_outs_request, parse_get_o_indexes_response,
    parse_get_random_outs_response, parse_query_blocks_lite_response, query_blocks_lite_request,
};
use serde_json::{json, Value};

// A hung endpoint must fail the job, not stall it.
const TIMEOUT: Duration = Duration::from_secs(20);

fn node() -> (String, u16) {
    let url = std::env::var("FUEGOD_RPC_URL")
        .expect("set FUEGOD_RPC_URL to a running fuegod, e.g. http://127.0.0.1:28180");
    let host_port = url.trim_start_matches("http://").trim_end_matches('/');
    let (host, port) = host_port
        .rsplit_once(':')
        .expect("FUEGOD_RPC_URL must be http://host:port");
    (host.to_string(), port.parse().expect("FUEGOD_RPC_URL port"))
}

fn read_chunk(s: &mut TcpStream, buf: &mut [u8], path: &str) -> usize {
    let n = s.read(buf).unwrap_or_else(|e| {
        panic!("{path}: fuegod did not answer within {TIMEOUT:?} ({e})")
    });
    assert!(n > 0, "{path}: fuegod closed the connection mid-response");
    n
}

fn post(path: &str, content_type: &str, body: &[u8]) -> Vec<u8> {
    let (host, port) = node();
    let mut s = TcpStream::connect((host.as_str(), port)).expect("connect to fuegod");
    s.set_read_timeout(Some(TIMEOUT)).unwrap();
    s.set_write_timeout(Some(TIMEOUT)).unwrap();
    write!(
        s,
        "POST {path} HTTP/1.1\r\nHost: {host}:{port}\r\nContent-Type: {content_type}\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )
    .unwrap();
    s.write_all(body).unwrap();

    let mut raw = Vec::new();
    let mut buf = [0u8; 8192];
    let body_start = loop {
        let n = read_chunk(&mut s, &mut buf, path);
        raw.extend_from_slice(&buf[..n]);
        if let Some(i) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
    };
    let head = String::from_utf8_lossy(&raw[..body_start]).to_ascii_lowercase();
    assert!(
        head.starts_with("http/1.1 200"),
        "{path}: {}",
        head.lines().next().unwrap_or("")
    );
    let len: usize = head
        .lines()
        .find_map(|l| l.strip_prefix("content-length:"))
        .map(|v| v.trim().parse().expect("Content-Length"))
        .unwrap_or_else(|| panic!("{path}: response has no Content-Length"));
    while raw.len() - body_start < len {
        let n = read_chunk(&mut s, &mut buf, path);
        raw.extend_from_slice(&buf[..n]);
    }
    raw[body_start..body_start + len].to_vec()
}

fn json_rpc(method: &str, params: Value) -> Value {
    let body = json!({"jsonrpc": "2.0", "id": "1", "method": method, "params": params});
    let resp: Value = serde_json::from_slice(&post(
        "/json_rpc",
        "application/json",
        body.to_string().as_bytes(),
    ))
    .unwrap();
    resp.get("result")
        .cloned()
        .unwrap_or_else(|| panic!("{method}: {resp}"))
}

fn hex32(s: &str) -> [u8; 32] {
    hex::decode(s).unwrap().try_into().unwrap()
}

fn genesis_hash() -> [u8; 32] {
    hex32(json_rpc("on_getblockhash", json!([0])).as_str().unwrap())
}

// (coinbase tx hash, amount, one-time key) of genesis output 0, from fuegod's JSON view.
fn genesis_coinbase_output() -> ([u8; 32], u64, [u8; 32]) {
    let block = json_rpc("f_block_json", json!({"hash": hex::encode(genesis_hash())}));
    let tx_hash = block["block"]["transactions"][0]["hash"].as_str().unwrap().to_string();
    let tx = json_rpc("f_transaction_json", json!({"hash": tx_hash}));
    let out = &tx["tx"]["vout"][0];
    (
        hex32(&tx_hash),
        out["amount"].as_u64().unwrap(),
        hex32(out["target"]["data"]["key"].as_str().unwrap()),
    )
}

#[test]
#[ignore = "needs a running fuegod; set FUEGOD_RPC_URL"]
fn query_blocks_lite_round_trip() {
    let genesis = genesis_hash();
    let raw = post(
        "/queryblockslite.bin",
        "application/octet-stream",
        &query_blocks_lite_request(&[genesis], 0),
    );
    let resp = parse_query_blocks_lite_response(&raw).expect("parse /queryblockslite.bin");
    assert_eq!(resp.status, "OK");
    assert!(resp.current_height >= 1, "current_height {}", resp.current_height);
    assert_eq!(resp.items.first().map(|b| b.block_id), Some(genesis));
}

#[test]
#[ignore = "needs a running fuegod; set FUEGOD_RPC_URL"]
fn get_random_outs_empty_groups() {
    let amounts = [0u64, 1_000_000];
    let raw = post(
        "/getrandom_outs.bin",
        "application/octet-stream",
        &get_random_outs_request(&amounts, 0),
    );
    let resp = parse_get_random_outs_response(&raw).expect("parse /getrandom_outs.bin");
    assert_eq!(
        resp.iter().map(|r| r.amount).collect::<Vec<_>>(),
        amounts.to_vec()
    );
}

#[test]
#[ignore = "needs a running fuegod; set FUEGOD_RPC_URL"]
fn get_random_outs_returns_known_output() {
    let (tx_hash, amount, key) = genesis_coinbase_output();
    let o_indexes = parse_get_o_indexes_response(&post(
        "/get_o_indexes.bin",
        "application/octet-stream",
        &get_o_indexes_request(&tx_hash),
    ))
    .expect("parse /get_o_indexes.bin");
    // Asking for more outputs than exist returns all of them (testnet unlock window is 0).
    let resp = parse_get_random_outs_response(&post(
        "/getrandom_outs.bin",
        "application/octet-stream",
        &get_random_outs_request(&[amount], 100),
    ))
    .expect("parse /getrandom_outs.bin");
    assert_eq!(resp.len(), 1);
    assert_eq!(resp[0].amount, amount);
    assert!(
        resp[0]
            .outs
            .iter()
            .any(|o| o.out_key == key && o.global_amount_index == o_indexes[0]),
        "genesis output (key {}, global index {}) missing from {:?}",
        hex::encode(key),
        o_indexes[0],
        resp[0].outs
    );
}
