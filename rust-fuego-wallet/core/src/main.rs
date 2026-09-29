#![allow(dead_code)]

mod base58;
mod crypto;
mod daemon;
mod fuegod;
mod keystore;
mod release;
mod scanner;
mod server;
mod swapd;
mod wallet_service;
mod wallet_slot;
mod walletd;

use clap::{Parser, Subcommand};
use std::path::PathBuf;
use std::sync::Arc;
use crate::wallet_slot::WalletSlot;

fn default_wallet_dir() -> PathBuf {
    directories::ProjectDirs::from("org", "usexfg", "fuego-wallet")
        .map(|d| d.data_local_dir().to_path_buf())
        .unwrap_or_else(|| PathBuf::from(".fuego-wallet"))
}

#[derive(Parser)]
#[command(name = "fuego-wallet", about = "Fuego-native wallet")]
struct Cli {
    #[arg(short = 'H', long, default_value = "127.0.0.1")]
    host: String,

#[arg(short = 'P', long, default_value_t = 18189)]
port: u16,

    #[arg(long)]
    seed: Option<String>,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    Serve {
        #[arg(long, default_value = "207.244.247.64")]
        daemon_host: String,

        #[arg(long, default_value_t = 18180)]
        daemon_port: u16,

        #[arg(long)]
        testnet: bool,

        #[arg(long)]
        local: bool,

        /// Launch xfg-swapd alongside fuegod (uses <wallet_dir>/swap_config.json
        /// unless overridden).
        #[arg(long)]
        swapd_config: Option<PathBuf>,

        /// Skip the xfg-swapd auto-launch even if a config is found.
        #[arg(long)]
        no_swapd: bool,

        /// Start with no wallet open; the GUI sends the vault seed with the
        /// `open_wallet` JSON-RPC method after unlock. Never creates master_seed.bin.
        #[arg(long)]
        await_wallet: bool,
    },
    Status,
}

fn read_seed_file(wallet_dir: &PathBuf) -> Option<[u8; 32]> {
    use zeroize::Zeroize;
    let mut data = std::fs::read(wallet_dir.join("master_seed.bin")).ok()?;
    let seed = (data.len() == 32).then(|| {
        let mut seed = [0u8; 32];
        seed.copy_from_slice(&data);
        seed
    });
    data.zeroize();
    seed
}

fn load_or_create_seed(wallet_dir: &PathBuf) -> Result<[u8; 32], Box<dyn std::error::Error>> {
    let seed_path = wallet_dir.join("master_seed.bin");
    if let Some(seed) = read_seed_file(wallet_dir) {
        return Ok(seed);
    }
    let mut seed = [0u8; 32];
    use rand::RngCore;
    rand::rngs::OsRng.fill_bytes(&mut seed);
    std::fs::write(&seed_path, &seed)?;
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&seed_path, std::fs::Permissions::from_mode(0o600));
    }
    log::info!("Created new wallet seed at {:?}", seed_path);
    Ok(seed)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let cli = Cli::parse();
    let wallet_dir = default_wallet_dir();
    std::fs::create_dir_all(&wallet_dir)?;

    match cli.command.unwrap_or(Commands::Status) {
        Commands::Serve { daemon_host, daemon_port, testnet, local, swapd_config, no_swapd, await_wallet } => {
            let (actual_host, actual_port, _daemon_guard) = if local {
                log::info!("--local: starting embedded fuegod...");
                let data_dir = wallet_dir.join("fuegod");
                let mut daemon = fuegod::DaemonProcess::new(daemon_port);
                match daemon.start(testnet, data_dir.to_str().unwrap_or("fuegod")).await {
                    Ok(url) => {
                        log::info!("Embedded fuegod ready at {}", url);
                        ("127.0.0.1".to_string(), daemon_port, Some(daemon))
                    }
                    Err(e) => {
                        // Local chain unavailable (e.g. corrupt DB mid-resync):
                        // stay up on the remote seed so the wallet keeps working.
                        log::warn!("Embedded fuegod unavailable: {} — falling back to remote {}:{}",
                            e, daemon_host, daemon_port);
                        (daemon_host.clone(), daemon_port, None)
                    }
                }
            } else {
                (daemon_host.clone(), daemon_port, None)
            };

            let daemon_url = format!("http://{}:{}", actual_host, actual_port);

            // 2. Wallet. Its state lives in the wallet dir root for the headless
            // --seed / master_seed.bin wallet (as before), under wallets/<id>/ otherwise.
            let slot = Arc::new(WalletSlot::new(wallet_dir.clone(), &daemon_url, testnet));
            if await_wallet {
                if cli.seed.is_some() {
                    return Err("--seed cannot be combined with --await-wallet".into());
                }
                // A master_seed.bin left by an older walletd held a wallet the GUI never
                // showed; keep syncing it so its funds can be swept (sweep_legacy_wallet).
                if let Some(seed) = read_seed_file(&wallet_dir) {
                    match slot.open_at(seed, &wallet_dir, true).await {
                        Ok(id) => log::info!("legacy walletd wallet {} found (master_seed.bin)", id),
                        Err(e) => log::warn!("legacy master_seed.bin wallet not opened: {}", e),
                    }
                }
                log::info!("waiting for open_wallet");
            } else {
                let seed = match &cli.seed {
                    Some(s) => {
                        let bytes = hex::decode(s.trim_start_matches("0x"))
                            .map_err(|e| format!("invalid seed hex: {}", e))?;
                        if bytes.len() != 32 {
                            return Err(format!("seed must be 32 bytes").into());
                        }
                        let mut seed = [0u8; 32];
                        seed.copy_from_slice(&bytes);
                        seed
                    }
                    None => load_or_create_seed(&wallet_dir)?,
                };
                slot.open_at(seed, &wallet_dir, false)
                    .await
                    .map_err(|e| format!("Failed to initialize SDK wallet: {}", e))?;
                if let Some(w) = slot.current().await {
                    log::info!("Wallet address: {}", w.lock().await.primary_address_string());
                }
            }

            // 2.5 Launch xfg-swapd when a swap config is available (unified
            // launcher; the GUI's Swap Settings screen writes the same config
            // path, so both flows interoperate).
            let mut _swapd_guard: Option<swapd::SwapdProcess> = None;
            if !no_swapd {
                let config = match &swapd_config {
                    Some(p) => Some(p.clone()),
                    None => swapd::find_swap_config(&wallet_dir),
                };
                match config {
                    Some(cfg) => match swapd::SwapdProcess::start(&cfg, &actual_host, daemon_port, testnet) {
                        Ok(proc) => {
                            let ready = proc.wait_ready(std::time::Duration::from_secs(15)).await;
                            if ready {
                                log::info!(
                                    "xfg-swapd started (config {}, rpc {})",
                                    cfg.display(),
                                    swapd::SWAPD_RPC_PORT
                                );
                            } else {
                                log::warn!(
                                    "xfg-swapd did not become ready within 15s (config {})",
                                    cfg.display()
                                );
                            }
                            _swapd_guard = Some(proc);
                        }
                        Err(e) => log::warn!("xfg-swapd not started: {}", e),
                    },
                    None => log::debug!("no swap config found; xfg-swapd not launched"),
                }
            }

            // 4. Start Axum server
            let bind = format!("{}:{}", cli.host, cli.port);
            server::run_server(slot, &daemon_url, &bind).await?;
        }

        Commands::Status => {
            println!("Wallet dir: {:?}", wallet_dir);
            let seed_path = wallet_dir.join("master_seed.bin");
            println!("Seed: {}", if seed_path.exists() { "exists" } else { "not found" });
            println!("Use 'fuego-wallet serve' to start.");
        }
    }

    Ok(())
}
