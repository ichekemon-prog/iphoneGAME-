// Phone Runner Probe 診断版5
// Remote Pairingで作ったトンネル(診断版4で成功)の上で、
// XCTest経由でWDAを起動し、Probe自身の画面上の目印を1回タップする。
use std::{
    ffi::{CStr, CString, c_char},
    future::Future,
    pin::Pin,
    sync::{
        Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use idevice::{
    Idevice, IdeviceError,
    dvt::xctest::{TestConfig, XCUITestService, listener::XCUITestListener},
    installation_proxy::InstallationProxyClient,
    pairing_file::PairingFile,
    provider::IdeviceProvider,
    remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native},
    rsd::RsdHandshake,
    tcp::{adapter::Adapter, handle::AdapterHandle},
    wda::WdaClient,
};

static RUNNING: AtomicBool = AtomicBool::new(false);
static STOP: AtomicBool = AtomicBool::new(false);
static STATUS: Mutex<String> = Mutex::new(String::new());
static TAP_POINT: Mutex<Option<(f64, f64)>> = Mutex::new(None);

fn status(value: &str) {
    if let Ok(mut s) = STATUS.lock() {
        *s = value.into();
    }
}

// Only numeric error codes and OS error kinds may leave the library.
fn safe_error(stage: &str, error: IdeviceError) -> String {
    let mut detail = format!("{stage}: 失敗 code={} sub={}", error.code(), error.sub_code());
    if let IdeviceError::Socket(io) = &error {
        detail.push_str(&format!(" io={:?} os={:?}", io.kind(), io.raw_os_error()));
    }
    detail
}

async fn step<T>(
    label: &str,
    seconds: u64,
    task: impl Future<Output = Result<T, IdeviceError>>,
) -> Result<T, String> {
    status(label);
    tokio::time::timeout(Duration::from_secs(seconds), task)
        .await
        .map_err(|_| format!("{label}: タイムアウト（{seconds}秒）"))?
        .map_err(|e| safe_error(label, e))
}

/// Lets idevice's WdaClient open device ports through our own tunnel.
#[derive(Debug)]
struct TunnelProvider {
    handle: AdapterHandle,
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

struct QuietListener;
impl XCUITestListener for QuietListener {}

fn ios_major(handshake: &RsdHandshake) -> u8 {
    ["OSVersion", "ProductVersion"]
        .iter()
        .filter_map(|k| handshake.properties.get(*k).and_then(|v| v.as_string()))
        .filter_map(|s| s.split('.').next().and_then(|m| m.parse().ok()))
        .next()
        .unwrap_or(26)
}

/// R0-R8: identical to 診断版4 (verified on the device).
async fn open_tunnel(path: String, addr: std::net::IpAddr) -> Result<(AdapterHandle, RsdHandshake), String> {
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
    Ok((handle, handshake))
}

/// Minimal HTTP POST to WDA through the tunnel. Returns (status, body).
async fn wda_post(provider: &TunnelProvider, path: &str, body: &str) -> Result<(u16, String), IdeviceError> {
    let mut dev = provider.connect(8100).await?;
    let request = format!(
        "POST {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    );
    dev.send_raw(request.as_bytes()).await?;
    let mut response = Vec::new();
    loop {
        let chunk = match dev.read_any(8192).await {
            Ok(c) => c,
            Err(_) if !response.is_empty() => break, // connection closed by WDA
            Err(e) => return Err(e),
        };
        if chunk.is_empty() { break; }
        response.extend_from_slice(&chunk);
        let text = String::from_utf8_lossy(&response);
        if let Some(h) = text.find("\r\n\r\n") {
            let len = text[..h].lines()
                .find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap_or(0)));
            if let Some(len) = len && response.len() >= h + 4 + len { break; }
        }
    }
    let text = String::from_utf8_lossy(&response).to_string();
    let status = text.split_whitespace().nth(1).and_then(|c| c.parse().ok()).unwrap_or(0);
    let body = text.split_once("\r\n\r\n").map(|(_, b)| b.to_string()).unwrap_or_default();
    Ok((status, body))
}

/// WDA error name only (e.g. "unknown command"), never the whole body.
fn wda_error_name(body: &str) -> String {
    let Some(i) = body.find("\"error\"") else { return "-".into() };
    let rest = &body[i + 7..];
    let Some(q1) = rest.find('"') else { return "-".into() };
    let rest = &rest[q1 + 1..];
    rest.split('"').next().unwrap_or("-").chars().take(60).collect()
}

async fn wda_call(provider: &TunnelProvider, label: &str, path: &str, body: &str) -> Result<(), String> {
    status(label);
    match tokio::time::timeout(Duration::from_secs(15), wda_post(provider, path, body)).await {
        Err(_) => Err(format!("{label}: タイムアウト（15秒）")),
        Ok(Err(e)) => Err(safe_error(label, e)),
        Ok(Ok((200, _))) => Ok(()),
        Ok(Ok((code, body))) => Err(format!("{label}: HTTP {code} / {}", wda_error_name(&body))),
    }
}

/// W3-W7: runs while the XCTest runner keeps WDA alive.
async fn drive_wda(handle: AdapterHandle, self_bundle: String) -> Result<String, String> {
    let provider = TunnelProvider { handle };
    let mut wda = WdaClient::new(&provider).with_timeout(Duration::from_secs(8));
    step("W3: WDAの起動待ち（最大60秒）", 65, wda.wait_until_ready(Duration::from_secs(60))).await?;
    let session = step("W4: WDAセッション開始", 20, wda.start_session(None)).await?;
    let mut notes = Vec::new();
    if !self_bundle.is_empty() {
        // WDA native endpoint (the "mobile:" scripts are Appium-only).
        let body = format!("{{\"bundleId\":\"{self_bundle}\"}}");
        match wda_call(&provider, "W5: Probeを前面に戻す", &format!("/session/{session}/wda/apps/activate"), &body).await {
            Ok(()) => notes.push("W5成功".to_string()),
            Err(e) => notes.push(format!("{e}（続行）")),
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    let point = TAP_POINT.lock().ok().and_then(|p| *p);
    let Some((x, y)) = point else {
        return Err("W6: タップ目標の位置が未設定です".into());
    };
    let actions = format!(
        "{{\"actions\":[{{\"type\":\"pointer\",\"id\":\"finger1\",\"parameters\":{{\"pointerType\":\"touch\"}},\"actions\":[{{\"type\":\"pointerMove\",\"duration\":0,\"x\":{x:.0},\"y\":{y:.0}}},{{\"type\":\"pointerDown\",\"button\":0}},{{\"type\":\"pause\",\"duration\":100}},{{\"type\":\"pointerUp\",\"button\":0}}]}}]}}"
    );
    let tapped = match wda_call(&provider, "W6a: W3C操作でタップ", &format!("/session/{session}/actions"), &actions).await {
        Ok(()) => "W6a(actions)".to_string(),
        Err(first) => {
            let body = format!("{{\"x\":{x:.0},\"y\":{y:.0}}}");
            wda_call(&provider, "W6b: wda/tapでタップ", &format!("/session/{session}/wda/tap"), &body)
                .await
                .map_err(|second| format!("{first}\n{second}"))?;
            format!("W6b(wda/tap)  ※{first}")
        }
    };
    notes.push(format!("タップ命令成功: {tapped}"));
    let summary = notes.join("\n");
    // Keep WDA alive for a short while and confirm it still answers.
    let mut ok = 0;
    for _ in 0..12 {
        status(&format!(
            "W7: WDA応答 {ok}/12 回\n{summary}\n画面の『WDAからのタップ回数』が1以上なら、iPhone単体でのタップ成功です。"
        ));
        tokio::time::sleep(Duration::from_secs(5)).await;
        match tokio::time::timeout(Duration::from_secs(8), wda.status()).await {
            Ok(Ok(_)) => ok += 1,
            Ok(Err(e)) => return Err(format!("{}\n{summary}", safe_error(&format!("W7: WDA応答確認（成功{ok}回の後）"), e))),
            Err(_) => return Err(format!("W7: WDA応答が8秒以内にありません（成功{ok}回の後）\n{summary}")),
        }
    }
    let _ = wda.delete_session(&session).await;
    Ok(format!(
        "診断版5.1: 完了。WDA応答{ok}/12回\n{summary}\n『WDAからのタップ回数』を確認してください。ゲーム操作・長時間・USB切断後は未検証です。"
    ))
}

async fn probe(path: String, host: String, runner: String, self_bundle: String) -> Result<(), String> {
    let addr = host.parse::<std::net::IpAddr>().map_err(|_| "接続先IPアドレスが不正です".to_string())?;
    if runner.is_empty() {
        return Err("WDAのBundle IDが未入力です".into());
    }
    let (mut handle, mut handshake) = open_tunnel(path, addr).await?;
    let ios = ios_major(&handshake);
    status(&format!("R8: 成功（{}サービス, iOS {ios}）", handshake.services.len()));

    let mut install: InstallationProxyClient = step("W1: アプリ一覧サービスへ接続", 20, handshake.connect(&mut handle)).await?;
    let cfg = step("W1: WDAアプリ情報を取得", 20, TestConfig::from_installation_proxy(&mut install, &runner, None)).await?;
    drop(install);

    status("W2: XCTestでWDAを起動中（WDA画面が前面に出る場合があります）");
    let mut listener = QuietListener;
    let runner_task = XCUITestService::run_over_rsd(handle.clone(), &handshake, ios, cfg, &mut listener, None);
    tokio::select! {
        result = runner_task => Err(match result {
            Ok(()) => "W2: XCTestが先に終了しました（WDAが停止）".to_string(),
            Err(e) => safe_error("W2: XCTest起動・維持", e),
        }),
        result = drive_wda(handle.clone(), self_bundle) => {
            let message = result?;
            status(&message);
            Ok(())
        }
    }
}

/// Copies arguments before returning. `runner` is the WDA xctrunner bundle id,
/// `self_bundle` is this app's bundle id (used to come back to the front).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn probe_start(
    path: *const c_char,
    host: *const c_char,
    runner: *const c_char,
    self_bundle: *const c_char,
) -> bool {
    if path.is_null() || host.is_null() || runner.is_null() || self_bundle.is_null() {
        return false;
    }
    if RUNNING.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).is_err() {
        return false;
    }
    let read = |p: *const c_char| unsafe { CStr::from_ptr(p) }.to_str().map(str::to_owned);
    let (Ok(path), Ok(host), Ok(runner), Ok(self_bundle)) = (read(path), read(host), read(runner), read(self_bundle)) else {
        RUNNING.store(false, Ordering::SeqCst);
        return false;
    };
    STOP.store(false, Ordering::SeqCst);
    status("診断版5.1: 開始します");
    let spawned = std::thread::Builder::new().name("runner-probe".into()).spawn(move || {
        let result = std::panic::catch_unwind(move || -> Result<(), String> {
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()
                .map_err(|_| "実行環境を作成できません".to_string())?;
            runtime.block_on(async {
                tokio::select! {
                    result = tokio::time::timeout(Duration::from_secs(270), probe(path, host, runner, self_bundle)) =>
                        result.map_err(|_| "試験全体がタイムアウトしました".to_string())?,
                    _ = async { while !STOP.load(Ordering::SeqCst) { tokio::time::sleep(Duration::from_millis(100)).await; } } => {
                        status("停止しました"); Ok(())
                    }
                }
            })
        });
        match result {
            Ok(Ok(())) => {}
            Ok(Err(e)) => status(&e),
            Err(_) => status("内部エラーで停止しました"),
        }
        RUNNING.store(false, Ordering::SeqCst);
    });
    if spawned.is_err() {
        RUNNING.store(false, Ordering::SeqCst);
        status("処理を開始できません");
        return false;
    }
    true
}

/// Screen point (UIKit points, window coordinates) of the tap target.
#[unsafe(no_mangle)]
pub extern "C" fn probe_set_tap_point(x: f64, y: f64) {
    if let Ok(mut p) = TAP_POINT.lock() {
        *p = if x.is_finite() && y.is_finite() && x > 0.0 && y > 0.0 { Some((x, y)) } else { None };
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn probe_stop() {
    STOP.store(true, Ordering::SeqCst);
}
#[unsafe(no_mangle)]
pub extern "C" fn probe_running() -> bool {
    RUNNING.load(Ordering::SeqCst)
}
#[unsafe(no_mangle)]
pub extern "C" fn probe_status() -> *mut c_char {
    let s = STATUS.lock().map(|s| s.clone()).unwrap_or_else(|_| "状態取得エラー".into());
    CString::new(s).unwrap_or_default().into_raw()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn probe_free_string(p: *mut c_char) {
    if !p.is_null() {
        drop(unsafe { CString::from_raw(p) });
    }
}
