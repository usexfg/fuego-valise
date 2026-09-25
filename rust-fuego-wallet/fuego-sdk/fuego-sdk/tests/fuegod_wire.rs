// Drift check: the SDK's `.bin` builders/parsers against a real fuegod (see AGENTS.md).

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

use fuego_sdk::serialization::{
    get_random_outs_request, parse_get_random_outs_response, parse_query_blocks_lite_response,
    query_blocks_lite_request,
};

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

fn genesis_hash() -> [u8; 32] {
    let body = br#"{"jsonrpc":"2.0","id":"1","method":"on_getblockhash","params":[0]}"#;
    let resp: serde_json::Value =
        serde_json::from_slice(&post("/json_rpc", "application/json", body)).unwrap();
    let hex_hash = resp["result"]
        .as_str()
        .unwrap_or_else(|| panic!("on_getblockhash: {resp}"));
    hex::decode(hex_hash).unwrap().try_into().unwrap()
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
fn get_random_outs_round_trip() {
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
