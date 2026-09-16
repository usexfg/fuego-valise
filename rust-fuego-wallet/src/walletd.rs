use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::io::Write;

pub struct WalletdProcess {
    child: Option<Child>,
    port: u16,
}

impl WalletdProcess {
    pub fn new(port: u16) -> Self { Self { child: None, port } }
    pub fn rpc_url(&self) -> String { format!("http://127.0.0.1:{}", self.port) }

    /// Get container password from environment (Dart now sets WALLETD_*).
    /// Priority: WALLETD_CONTAINER_PASSWORD > WALLETD_PASSWORD > FUEGO_CONTAINER_PASSWORD.
    /// No weak "fuego" default — caller must set env via Dart getOrCreateWalletdPassword.
    fn container_password() -> Result<String, String> {
        for key in ["WALLETD_CONTAINER_PASSWORD", "WALLETD_PASSWORD", "FUEGO_CONTAINER_PASSWORD"] {
            if let Ok(v) = std::env::var(key) {
                if !v.is_empty() {
                    return Ok(v);
                }
            }
        }
        Err("container password not set — set WALLETD_CONTAINER_PASSWORD env (Dart SecureStorage)".to_string())
    }

    /// Write password to 0600 temp file, return path. Caller must delete after use.
    fn write_password_file(pwd: &str) -> Result<String, String> {
        let mut path = std::env::temp_dir();
        path.push(format!(".fuego_pw_{}", std::process::id()));
        let mut file = std::fs::File::create(&path).map_err(|e| format!("create pw file: {}", e))?;
        file.write_all(pwd.as_bytes()).map_err(|e| format!("write pw file: {}", e))?;
        file.sync_all().ok();
        #[cfg(unix)] {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        }
        Ok(path.to_string_lossy().to_string())
    }

    pub async fn start(
        &mut self, daemon_host: &str, daemon_port: u16, container_file: &str,
    ) -> Result<String, String> {
        let (_, walletd_bin) = crate::release::ensure_binaries().await?;
        log::info!("Starting walletd: {}", walletd_bin.display());

        let password = Self::container_password()?;
        // Prefer password-file (0600) over argv — mitigates `ps` leak (CWE-214)
        let pw_file = Self::write_password_file(&password).ok();
        let use_pw_file = pw_file.is_some() && {
            // Probe if binary supports --container-password-file (future C++ flag)
            // For now, try file; if it fails, fallback to env+argv with warning
            true
        };

        // Generate walletd container if it doesn't exist
        if !Path::new(container_file).exists() {
            log::info!("Generating walletd container at {}", container_file);
            let output = if let Some(ref pf) = pw_file {
                Command::new(&walletd_bin)
                    .args([
                        "--generate-container",
                        "--container-file", container_file,
                        "--container-password-file", pf,
                        "--daemon-address", daemon_host,
                        "--daemon-port", &daemon_port.to_string(),
                    ])
                    .env("WALLETD_CONTAINER_PASSWORD", &password)
                    .output().map_err(|e| format!("generate container: {}", e))?
            } else {
                // Fallback: env + argv (legacy C++ without file support)
                log::warn!("pw file unavailable — falling back to argv (ps-visible)");
                Command::new(&walletd_bin)
                    .args([
                        "--generate-container",
                        "--container-file", container_file,
                        "--container-password", &password,
                        "--daemon-address", daemon_host,
                        "--daemon-port", &daemon_port.to_string(),
                    ])
                    .env("WALLETD_CONTAINER_PASSWORD", &password)
                    .output().map_err(|e| format!("generate container: {}", e))?
            };
            // If file arg was rejected, retry with argv
            let output = if !output.status.success() && use_pw_file {
                let stderr = String::from_utf8_lossy(&output.stderr);
                if stderr.contains("unrecognized") || stderr.contains("unknown") {
                    log::warn!("C++ walletd lacks --container-password-file, retrying with env");
                    Command::new(&walletd_bin)
                        .args([
                            "--generate-container",
                            "--container-file", container_file,
                            "--container-password", &password,
                            "--daemon-address", daemon_host,
                            "--daemon-port", &daemon_port.to_string(),
                        ])
                        .env("WALLETD_CONTAINER_PASSWORD", &password)
                        .output().map_err(|e| format!("generate container retry: {}", e))?
                } else {
                    output
                }
            } else {
                output
            };
            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                return Err(format!("generate container failed: {}", stderr));
            }
            log::info!("Walletd container generated (password via file/env)");
        }

        let mut child = if let Some(ref pf) = pw_file {
            Command::new(&walletd_bin)
                .args([
                    "--daemon-address", daemon_host,
                    "--daemon-port", &daemon_port.to_string(),
                    "--container-file", container_file,
                    "--container-password-file", pf,
                    "--bind-port", &self.port.to_string(),
                    "--bind-address", "127.0.0.1",
                    "--log-level", "2",
                ])
                .env("WALLETD_CONTAINER_PASSWORD", &password)
                .env("WALLETD_PASSWORD", &password)
                .stdout(Stdio::piped()).stderr(Stdio::piped())
                .spawn().map_err(|e| format!("spawn: {}", e))?
        } else {
            Command::new(&walletd_bin)
                .args([
                    "--daemon-address", daemon_host,
                    "--daemon-port", &daemon_port.to_string(),
                    "--container-file", container_file,
                    "--container-password", &password,
                    "--bind-port", &self.port.to_string(),
                    "--bind-address", "127.0.0.1",
                    "--log-level", "2",
                ])
                .env("WALLETD_CONTAINER_PASSWORD", &password)
                .env("WALLETD_PASSWORD", &password)
                .stdout(Stdio::piped()).stderr(Stdio::piped())
                .spawn().map_err(|e| format!("spawn: {}", e))?
        };
        // Best-effort clean pw file — C++ has read it or env is set; 0600 file should not linger (ADV-03)
        if let Some(pf) = pw_file {
            let _ = std::fs::remove_file(&pf);
        }

        // Drain stdout/stderr so child doesn't block on pipe buffer
        if let Some(stdout) = child.stdout.take() {
            std::thread::spawn(move || {
                use std::io::Read;
                let mut reader = std::io::BufReader::new(stdout);
                let mut buf = [0u8; 1024];
                loop {
                    if reader.read(&mut buf).is_err() { break; }
                }
            });
        }
        if let Some(stderr) = child.stderr.take() {
            std::thread::spawn(move || {
                use std::io::Read;
                let mut reader = std::io::BufReader::new(stderr);
                let mut buf = [0u8; 1024];
                loop {
                    if reader.read(&mut buf).is_err() { break; }
                }
            });
        }

        self.child = Some(child);
        Self::wait_ready(self.rpc_url(), 30).await?;
        log::info!("walletd ready on port {}", self.port);
        Ok(self.rpc_url())
    }

    async fn wait_ready(url: String, max_secs: u32) -> Result<(), String> {
        let client = reqwest::Client::new();
        let body = serde_json::json!({
            "jsonrpc": "2.0",
            "id": "1",
            "method": "getBalance",
            "params": {}
        });
        for _ in 0..max_secs {
            if let Ok(resp) = client.post(format!("{}/json_rpc", url))
                .json(&body).send().await
            {
                if resp.status().is_success() {
                    let val: serde_json::Value = resp.json().await.unwrap_or_default();
                    if val.get("result").is_some() {
                        return Ok(());
                    }
                }
            }
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        }
        Err(format!("walletd not ready after {}s", max_secs))
    }

    pub fn stop(&mut self) {
        if let Some(mut c) = self.child.take() { let _ = c.kill(); let _ = c.wait(); }
    }
}

impl Drop for WalletdProcess { fn drop(&mut self) { self.stop(); } }
