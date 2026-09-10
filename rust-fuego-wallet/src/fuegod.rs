use std::process::{Child, Command, Stdio};

pub struct DaemonProcess {
    child: Option<Child>,
    port: u16,
}

impl DaemonProcess {
    pub fn new(port: u16) -> Self { Self { child: None, port } }
    pub fn rpc_url(&self) -> String { format!("http://127.0.0.1:{}", self.port) }

    pub async fn start(&mut self, testnet: bool, data_dir: &str) -> Result<String, String> {
        let (fuegod, _) = crate::release::ensure_binaries().await?;
        std::fs::create_dir_all(data_dir).map_err(|e| format!("mkdir: {}", e))?;

        let port_str = self.port.to_string();
        let mut args = vec!["--data-dir", data_dir, "--rpc-bind-port", &port_str, "--rpc-bind-ip", "127.0.0.1", "--log-level", "1",
            // Headless: no TTY on stdin under the GUI.
            "--no-console"];
        if testnet { args.push("--testnet"); }

        log::info!("Starting fuegod: {}", fuegod.display());
        let child = Command::new(&fuegod).args(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped()).stderr(Stdio::piped())
            .spawn().map_err(|e| format!("spawn: {}", e))?;

        self.child = Some(child);
        Self::wait_ready(self.rpc_url(), 60).await?;
        log::info!("fuegod ready on port {}", self.port);
        Ok(self.rpc_url())
    }

    async fn wait_ready(url: String, max_secs: u32) -> Result<(), String> {
        let check = format!("{}/getinfo", url);
        for _ in 0..max_secs {
            if let Ok(resp) = reqwest::get(&check).await {
                if resp.status().is_success() { return Ok(()); }
            }
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        }
        Err(format!("fuegod not ready after {}s", max_secs))
    }

    pub fn stop(&mut self) {
        if let Some(mut c) = self.child.take() { let _ = c.kill(); let _ = c.wait(); }
    }
}

impl Drop for DaemonProcess { fn drop(&mut self) { self.stop(); } }
