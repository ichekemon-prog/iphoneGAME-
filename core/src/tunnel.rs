//! Engine: Remote Pairing tunnel + XCTest(WDA) launcher. Game independent.
use std::{future::Future, pin::Pin};

use idevice::{
    Idevice, IdeviceError,
    dvt::xctest::{TestConfig, XCUITestService, listener::XCUITestListener},
    installation_proxy::InstallationProxyClient,
    pairing_file::PairingFile,
    provider::IdeviceProvider,
    remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native},
    rsd::RsdHandshake,
    tcp::{adapter::Adapter, handle::AdapterHandle},
};

use crate::{safe_error, status, step};

/// Lets idevice clients open device ports through our own tunnel.
#[derive(Debug, Clone)]
pub struct TunnelProvider {
    pub handle: AdapterHandle,
}

impl IdeviceProvider for TunnelProvider {
    fn connect(&self, port: u16) -> Pin<Box<dyn Future<Output = Result<Idevice, IdeviceError>> + Send>> {
        let mut handle = self.handle.clone();
        Box::pin(async move {
            let stream = handle.connect(port).await.map_err(IdeviceError::Socket)?;
            Ok(Idevice::new(Box::new(stream), "tunnel"))
        })
    }
    fn label(&self) -> &str {
        "tunnel"
    }
    fn get_pairing_file(&self) -> Pin<Box<dyn Future<Output = Result<PairingFile, IdeviceError>> + Send>> {
        // The tunnel path never uses the lockdown pairing record.
        Box::pin(async { Err(IdeviceError::NoEstablishedConnection) })
    }
}

pub struct Tunnel {
    pub handle: AdapterHandle,
    pub handshake: RsdHandshake,
    pub ios_major: u8,
    pub rsd_port: u16,
}

impl Tunnel {
    /// Re-reads the advertised services over the same tunnel (e.g. after a DDI mount).
    pub async fn refresh(&mut self) -> Result<(), IdeviceError> {
        let stream = self.handle.connect(self.rsd_port).await.map_err(IdeviceError::Socket)?;
        self.handshake = RsdHandshake::new(stream).await?;
        Ok(())
    }

    pub fn provider(&self) -> TunnelProvider {
        TunnelProvider { handle: self.handle.clone() }
    }
}

fn ios_major(handshake: &RsdHandshake) -> u8 {
    ["OSVersion", "ProductVersion"]
        .iter()
        .filter_map(|k| handshake.properties.get(*k).and_then(|v| v.as_string()))
        .filter_map(|s| s.split('.').next().and_then(|m| m.parse().ok()))
        .next()
        .unwrap_or(26)
}

/// R0-R8 (verified on the device in 診断版4〜6).
pub async fn open(path: String, addr: std::net::IpAddr) -> Result<Tunnel, String> {
    let mut pairing = step("R0: 保存済みRemote Pairing情報を確認", 5, RpPairingFile::read_from_file(path)).await?;
    let stream = step("R1: 接続先49152へ接続", 10, async {
        Ok(tokio::net::TcpStream::connect((addr, 49152)).await?)
    })
    .await?;
    let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), "PhoneRunnerProbe");
    // connect() would fall back to fresh pairing. Verify existing keys only.
    step("R2: Remote Pairingの応答を確認", 15, rpc.attempt_pair_verify()).await?;
    step("R3: 保存済み認証情報で認証", 15, rpc.validate_pairing(&mut pairing)).await?;
    let port = step("R4: 通信経路を要求", 15, rpc.create_tcp_listener()).await?;
    if port == 0 {
        return Err("R4: 無効な接続ポート".into());
    }
    let stream = step("R5: 通信経路へ接続", 10, async {
        Ok(tokio::net::TcpStream::connect((addr, port)).await?)
    })
    .await?;
    let tunnel = step("R6: 暗号化・トンネル確立", 20, connect_tls_psk_tunnel_native(stream, rpc.encryption_key())).await?;
    let client_ip = tunnel.info.client_address.parse::<std::net::IpAddr>()
        .map_err(|_| "R6: クライアントIPの形式が不正".to_string())?;
    let server_ip = tunnel.info.server_address.parse::<std::net::IpAddr>()
        .map_err(|_| "R6: サーバーIPの形式が不正".to_string())?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;
    if rsd_port == 0 || mtu <= 60 {
        return Err("R6: トンネル設定が不正".into());
    }
    let mut adapter = Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut handle = adapter.to_async_handle();
    let stream = step("R7: サービス確認先へ接続", 15, async {
        handle.connect(rsd_port).await.map_err(IdeviceError::Socket)
    })
    .await?;
    let handshake = step("R8: 利用可能なサービスを確認", 15, RsdHandshake::new(stream)).await?;
    if handshake.services.is_empty() {
        return Err("R8: 応答はありましたがサービス一覧が空です".into());
    }
    let ios_major = ios_major(&handshake);
    status(&format!("R8: 成功（{}サービス, iOS {ios_major}）", handshake.services.len()));
    Ok(Tunnel { handle, handshake, ios_major, rsd_port })
}

/// Installed user apps as (display name, bundle id), sorted by name.
pub async fn list_user_apps(t: &mut Tunnel) -> Result<Vec<(String, String)>, String> {
    let mut install: InstallationProxyClient =
        step("A1: アプリ一覧サービスへ接続", 20, t.handshake.connect(&mut t.handle)).await?;
    let apps = step("A2: アプリ一覧を取得", 30, install.get_apps(Some("User"), None)).await?;
    let mut list: Vec<(String, String)> = apps
        .into_iter()
        .map(|(id, info)| {
            let name = info
                .as_dictionary()
                .and_then(|d| d.get("CFBundleDisplayName").or_else(|| d.get("CFBundleName")))
                .and_then(|v| v.as_string())
                .unwrap_or("-")
                .to_string();
            (name, id)
        })
        .collect();
    list.sort();
    Ok(list)
}

pub async fn runner_config(t: &mut Tunnel, runner: &str) -> Result<TestConfig, String> {
    let mut install: InstallationProxyClient =
        step("W1: アプリ一覧サービスへ接続", 20, t.handshake.connect(&mut t.handle)).await?;
    step("W1: WDAアプリ情報を取得", 20, TestConfig::from_installation_proxy(&mut install, runner, None)).await
}

/// Remembers how far the runner got, so a failure can say where it stopped.
#[derive(Default)]
struct TraceListener {
    stage: &'static str,
    notes: Vec<String>,
}

impl TraceListener {
    fn note(&mut self, text: &str) {
        let short: String = text.chars().take(160).collect();
        self.notes.push(short);
        if self.notes.len() > 3 {
            self.notes.remove(0);
        }
    }
}

impl XCUITestListener for TraceListener {
    async fn did_begin_initializing_for_ui_testing(&mut self) -> Result<(), IdeviceError> {
        self.stage = "UIテスト初期化開始";
        Ok(())
    }
    async fn exchange_protocol_version(&mut self, _c: u64, _m: u64) -> Result<(), IdeviceError> {
        self.stage = "ランナー接続";
        Ok(())
    }
    async fn test_bundle_ready_with_protocol_version(&mut self, _p: u64, _m: u64) -> Result<(), IdeviceError> {
        self.stage = "テストバンドル読込済み";
        Ok(())
    }
    async fn test_runner_ready_with_capabilities(&mut self) -> Result<(), IdeviceError> {
        self.stage = "ランナー準備完了";
        Ok(())
    }
    async fn did_begin_executing_test_plan(&mut self) -> Result<(), IdeviceError> {
        self.stage = "WDA実行開始";
        Ok(())
    }
    async fn log_message(&mut self, message: &str) -> Result<(), IdeviceError> {
        self.note(message);
        Ok(())
    }
    async fn initialization_for_ui_testing_did_fail(&mut self, description: &str) -> Result<(), IdeviceError> {
        self.stage = "UIテスト初期化失敗";
        self.note(description);
        Ok(())
    }
    async fn did_fail_to_bootstrap(&mut self, description: &str) -> Result<(), IdeviceError> {
        self.stage = "ランナー起動失敗";
        self.note(description);
        Err(IdeviceError::UnexpectedResponse(format!("test runner failed to bootstrap: {description}")))
    }
}

/// Runs the XCTest runner hosting WDA until it ends. Race this against the
/// work that uses WDA: when this returns, WDA is gone.
pub async fn run_wda(t: &Tunnel, cfg: TestConfig) -> String {
    let mut listener = TraceListener::default();
    let mut message = match XCUITestService::run_over_rsd(t.handle.clone(), &t.handshake, t.ios_major, cfg, &mut listener, None).await {
        Ok(()) => "W2: XCTestが先に終了しました（WDAが停止）".to_string(),
        Err(e) => safe_error("W2: XCTest起動・維持", e),
    };
    let stage = if listener.stage.is_empty() { "ランナーからの応答なし（起動・許可の段階）" } else { listener.stage };
    message.push_str(&format!(" / 到達: {stage}"));
    if !listener.notes.is_empty() {
        message.push_str(&format!(" / 内容: {}", listener.notes.join(" | ")));
    }
    message
}
