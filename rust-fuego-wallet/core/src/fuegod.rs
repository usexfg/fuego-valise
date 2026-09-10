use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};

pub struct DaemonProcess {
    child: Option<Child>,
    port: u16,
}

/// Recent stderr kept in memory so startup failures can report the real
/// cause (e.g. Boost `IInputStream` storage errors) instead of a bare timeout.
type LogTail = Arc<Mutex<String>>;

impl DaemonProcess {
    pub fn new(port: u16) -> Self { Self { child: None, port } }
    pub fn rpc_url(&self) -> String { format!("http://127.0.0.1:{}", self.port) }

    pub async fn start(&mut self, testnet: bool, data_dir: &str) -> Result<String, String> {
        let (fuegod, _) = crate::release::ensure_binaries().await?;
        std::fs::create_dir_all(data_dir).map_err(|e| format!("mkdir: {}", e))?;

        match self.try_start(&fuegod, testnet, data_dir).await {
            Ok(url) => Ok(url),
            Err(e) if is_storage_error(&e) => {
                // Boost `Failed to read from IInputStream` during "Loading
                // blockchain" almost always means a corrupt blockindexes.dat
                // (unclean shutdown). The index is rebuildable from blocks.dat,
                // so quarantine it and retry once instead of crash-looping.
                log::warn!("fuegod storage error ({}); quarantining index + retrying", e);
                if quarantine_blockindexes(data_dir, testnet) {
                    self.try_start(&fuegod, testnet, data_dir).await
                } else {
                    Err(e)
                }
            }
            Err(e) => Err(e),
        }
    }

    async fn try_start(&mut self, fuegod: &Path, testnet: bool, data_dir: &str) -> Result<String, String> {
        // Defensive: never reuse a dead handle from a previous attempt.
        self.stop();

        let port_str = self.port.to_string();
        let mut args = vec!["--data-dir", data_dir, "--rpc-bind-port", &port_str, "--rpc-bind-ip", "127.0.0.1", "--log-level", "1",
            // Headless under the GUI: no TTY on stdin, so the interactive
            // daemon console must stay off.
            "--no-console"];
        if testnet { args.push("--testnet"); }

        log::info!("Starting fuegod: {}", fuegod.display());
        let mut cmd = Command::new(fuegod);
        cmd.args(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped()).stderr(Stdio::piped());

        #[cfg(windows)]
        { cmd.creation_flags(0x08000000); } // CREATE_NO_WINDOW

        let mut child = cmd.spawn().map_err(|e| format!("spawn: {}", e))?;

        // fuegod logs heavily on a synced data dir. The pipe buffer is only
        // 64KB — if the parent never reads, fuegod blocks on write and never
        // binds its RPC port. Drain both pipes on dedicated threads and
        // forward the output to the wallet proxy's own log stream.
        let tail: LogTail = Arc::new(Mutex::new(String::new()));
        drain_async(child.stdout.take(), "fuegod:out", Arc::clone(&tail));
        drain_async(child.stderr.take(), "fuegod:err", Arc::clone(&tail));

        self.child = Some(child);
        // Poll RPC readiness, but bail out early when the child has already
        // exited — otherwise a crash at second 2 is reported as a 240s timeout.
        let url = self.rpc_url();
        let check = format!("{}/getinfo", url);
        for _ in 0..120 {
            if let Some(child) = self.child.as_mut() {
                match child.try_wait() {
                    Ok(Some(status)) => {
                        self.child = None;
                        return Err(format!(
                            "fuegod exited during startup ({}): {}",
                            status, tail_text(&tail),
                        ));
                    }
                    Ok(None) => {}
                    Err(e) => {
                        self.child = None;
                        return Err(format!("fuegod wait: {}: {}", e, tail_text(&tail)));
                    }
                }
            } else {
                return Err(format!("fuegod handle lost: {}", tail_text(&tail)));
            }
            if let Ok(resp) = reqwest::get(&check).await {
                if resp.status().is_success() {
                    log::info!("fuegod ready on port {}", self.port);
                    return Ok(url);
                }
            }
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        }
        // Timeout with the child still alive (e.g. stuck sync): kill it so a
        // retry — or a later start — doesn't contend on the datadir/port.
        self.stop();
        Err(format!("fuegod not ready after 240s: {}", tail_text(&tail)))
    }

    pub fn stop(&mut self) {
        if let Some(mut c) = self.child.take() { let _ = c.kill(); let _ = c.wait(); }
    }
}

/// True when the startup failure looks like Boost serialization failing to
/// load the local chain DB (`Exception: Failed to read from IInputStream`).
fn is_storage_error(msg: &str) -> bool {
    msg.contains("IInputStream")
}

/// Last ~2KB of captured daemon output for error reports.
fn tail_text(tail: &LogTail) -> String {
    let t = tail.lock().map(|g| g.clone()).unwrap_or_default();
    let t = t.trim();
    if t.is_empty() { "(no daemon output)".to_string() } else { t.to_string() }
}

/// Move a possibly-corrupt, rebuildable `blockindexes.dat` aside so the next
/// start rebuilds it from `blocks.dat`. Returns true when a quarantine
/// happened (caller should retry once).
fn quarantine_blockindexes(data_dir: &str, testnet: bool) -> bool {
    // Mainnet + testnet index names used by the C++ daemon.
    let names: &[&str] = if testnet {
        &["testnet_testnet_blockindexes.dat", "blockindexes.dat"]
    } else {
        &["blockindexes.dat"]
    };
    let dir = Path::new(data_dir);
    for name in names {
        let src = dir.join(name);
        if src.is_file() {
            let backup = PathBuf::from(format!(
                "{}.bak-corrupt-{}",
                src.display(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs())
                    .unwrap_or(0),
            ));
            match std::fs::rename(&src, &backup) {
                Ok(()) => {
                    log::warn!("Quarantined corrupt {} -> {}", src.display(), backup.display());
                    return true;
                }
                Err(e) => log::warn!("Could not quarantine {}: {}", src.display(), e),
            }
        }
    }
    false
}

#[cfg(unix)]
fn drain_async<R: Read + Send + 'static>(pipe: Option<R>, label: &'static str, tail: LogTail) {
    if let Some(mut p) = pipe {
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match p.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        let line = String::from_utf8_lossy(&buf[..n]);
                        let line = line.trim_end();
                        log::info!("{} {}", label, line);
                        if let Ok(mut t) = tail.lock() {
                            t.push_str(line);
                            t.push('\n');
                            // Keep only the tail — startup diagnostics, not history.
                            if t.len() > 2048 {
                                let skip = t.len() - 2048;
                                *t = t[skip..].to_string();
                            }
                        }
                    }
                }
            }
        });
    }
}

#[cfg(windows)]
fn drain_async<R: Read + Send + 'static>(pipe: Option<R>, label: &'static str, tail: LogTail) {
    if let Some(mut p) = pipe {
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match p.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        let line = String::from_utf8_lossy(&buf[..n]);
                        let line = line.trim_end();
                        log::info!("{} {}", label, line);
                        if let Ok(mut t) = tail.lock() {
                            t.push_str(line);
                            t.push('\n');
                            if t.len() > 2048 {
                                let skip = t.len() - 2048;
                                *t = t[skip..].to_string();
                            }
                        }
                    }
                }
            }
        });
    }
}

impl Drop for DaemonProcess { fn drop(&mut self) { self.stop(); } }
