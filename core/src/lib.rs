// Phone Runner Probe 診断版6
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

#[derive(Clone, Copy)]
enum Route {
    /// Through the Remote Pairing tunnel (device port 8100).
    Tunnel,
    /// Directly from this app to 127.0.0.1:8100 on the same iPhone.
    Local,
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

/// Minimal HTTP/1.1 request to WDA. Returns (status, body bytes).
async fn wda_http(
    provider: &TunnelProvider,
    route: Route,
    method: &str,
    path: &str,
    body: &str,
) -> Result<(u16, Vec<u8>), IdeviceError> {
    let mut dev = match route {
        Route::Tunnel => provider.connect(8100).await?,
        Route::Local => {
            let s = tokio::net::TcpStream::connect(("127.0.0.1", 8100)).await?;
            Idevice::new(Box::new(s), "local")
        }
    };
    let mut request = format!("{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n");
    if method == "POST" {
        request.push_str(&format!("Content-Type: application/json\r\nContent-Length: {}\r\n", body.len()));
    }
    request.push_str("\r\n");
    if method == "POST" {
        request.push_str(body);
    }
    dev.send_raw(request.as_bytes()).await?;
    let mut response: Vec<u8> = Vec::new();
    let mut header_end: Option<usize> = None;
    let mut content_length: Option<usize> = None;
    loop {
        let chunk = match dev.read_any(65536).await {
            Ok(c) => c,
            Err(_) if header_end.is_some() => break, // connection closed by WDA
            Err(e) => return Err(e),
        };
        if chunk.is_empty() {
            break;
        }
        response.extend_from_slice(&chunk);
        if header_end.is_none()
            && let Some(h) = find(&response, b"\r\n\r\n")
        {
            header_end = Some(h + 4);
            let head = String::from_utf8_lossy(&response[..h]).to_ascii_lowercase();
            content_length = head
                .lines()
                .find_map(|l| l.strip_prefix("content-length:").and_then(|v| v.trim().parse().ok()));
        }
        if let (Some(h), Some(len)) = (header_end, content_length)
            && response.len() >= h + len
        {
            break;
        }
    }
    let h = header_end.ok_or(IdeviceError::UnexpectedResponse("no http header".into()))?;
    let status = String::from_utf8_lossy(&response[..h])
        .split_whitespace()
        .nth(1)
        .and_then(|c| c.parse().ok())
        .unwrap_or(0);
    Ok((status, response.split_off(h)))
}

/// WDA error name only (e.g. "unknown command"), never the whole body.
fn wda_error_name(body: &[u8]) -> String {
    let body = String::from_utf8_lossy(&body[..body.len().min(4096)]).to_string();
    let Some(i) = body.find("\"error\"") else { return "-".into() };
    let rest = &body[i + 7..];
    let Some(q1) = rest.find('"') else { return "-".into() };
    let rest = &rest[q1 + 1..];
    rest.split('"').next().unwrap_or("-").chars().take(60).collect()
}

async fn wda_call(
    provider: &TunnelProvider,
    route: Route,
    label: &str,
    method: &str,
    path: &str,
    body: &str,
) -> Result<Vec<u8>, String> {
    match tokio::time::timeout(Duration::from_secs(15), wda_http(provider, route, method, path, body)).await {
        Err(_) => Err(format!("{label}: タイムアウト（15秒）")),
        Ok(Err(e)) => Err(safe_error(label, e)),
        Ok(Ok((200, body))) => Ok(body),
        Ok(Ok((code, body))) => Err(format!("{label}: HTTP {code} / {}", wda_error_name(&body))),
    }
}

/// W3-W6: start WDA session, bring Probe back, tap the target (verified in 5.1).
/// L1: try WDA directly on 127.0.0.1:8100 from inside the app.
/// B0-B3: send Probe to the background (home screen) for 90 s and check that
/// the tunnel, WDA and screenshots keep working, then come back.
async fn drive_wda(handle: AdapterHandle, self_bundle: String) -> Result<String, String> {
    let provider = TunnelProvider { handle };
    let mut wda = WdaClient::new(&provider).with_timeout(Duration::from_secs(8));
    step("W3: WDAの起動待ち（最大60秒）", 65, wda.wait_until_ready(Duration::from_secs(60))).await?;
    let session = step("W4: WDAセッション開始", 20, wda.start_session(None)).await?;
    let activate_path = format!("/session/{session}/wda/apps/activate");
    let activate_body = format!("{{\"bundleId\":\"{self_bundle}\"}}");
    let mut notes = Vec::new();

    status("W5: Probeを前面に戻す");
    match wda_call(&provider, Route::Tunnel, "W5", "POST", &activate_path, &activate_body).await {
        Ok(_) => notes.push("W5成功".to_string()),
        Err(e) => notes.push(format!("{e}（続行）")),
    }
    tokio::time::sleep(Duration::from_secs(2)).await;

    let Some((x, y)) = TAP_POINT.lock().ok().and_then(|p| *p) else {
        return Err("W6: タップ目標の位置が未設定です".into());
    };
    let actions = format!(
        "{{\"actions\":[{{\"type\":\"pointer\",\"id\":\"finger1\",\"parameters\":{{\"pointerType\":\"touch\"}},\"actions\":[{{\"type\":\"pointerMove\",\"duration\":0,\"x\":{x:.0},\"y\":{y:.0}}},{{\"type\":\"pointerDown\",\"button\":0}},{{\"type\":\"pause\",\"duration\":100}},{{\"type\":\"pointerUp\",\"button\":0}}]}}]}}"
    );
    status("W6: WDAで目標をタップ");
    wda_call(&provider, Route::Tunnel, "W6", "POST", &format!("/session/{session}/actions"), &actions).await?;
    notes.push("W6タップ命令成功".to_string());

    // L1: does WDA also answer on the iPhone's own loopback?
    status("L1: 端末内直結(127.0.0.1:8100)を確認");
    let local_ok = match wda_call(&provider, Route::Local, "L1", "GET", "/status", "").await {
        Ok(_) => {
            notes.push("L1: 端末内直結OK".to_string());
            true
        }
        Err(e) => {
            notes.push(format!("{e}（直結不可）"));
            false
        }
    };

    // B0: go to the home screen. Probe moves to the background.
    status("B0: ホーム画面へ移動（Probeは背景へ）");
    tokio::time::sleep(Duration::from_secs(1)).await;
    wda_call(&provider, Route::Tunnel, "B0: ホーム画面へ", "POST", "/wda/homescreen", "{}").await?;

    // B1: 90 s in the background.
    let started = tokio::time::Instant::now();
    let (mut tun_ok, mut tun_ng, mut loc_ok, mut loc_ng, mut tun_fail_run) = (0, 0, 0, 0, 0);
    let mut shots: Vec<String> = Vec::new();
    let mut round = 0;
    while started.elapsed() < Duration::from_secs(90) {
        tokio::time::sleep(Duration::from_secs(5)).await;
        round += 1;
        match wda_call(&provider, Route::Tunnel, "B1", "GET", "/status", "").await {
            Ok(_) => {
                tun_ok += 1;
                tun_fail_run = 0;
            }
            Err(_) => {
                tun_ng += 1;
                tun_fail_run += 1;
            }
        }
        if local_ok {
            match wda_call(&provider, Route::Local, "B1L", "GET", "/status", "").await {
                Ok(_) => loc_ok += 1,
                Err(_) => loc_ng += 1,
            }
        }
        if round == 6 || round == 12 {
            let route = if round == 12 && local_ok { Route::Local } else { Route::Tunnel };
            let name = if matches!(route, Route::Local) { "直結" } else { "トンネル" };
            match wda_call(&provider, route, "B2: 画面取得", "GET", "/screenshot", "").await {
                Ok(body) => shots.push(format!("{}秒 {name}: {}KB", started.elapsed().as_secs(), body.len() / 1024)),
                Err(e) => shots.push(format!("{}秒 {name}: {e}", started.elapsed().as_secs())),
            }
        }
        status(&format!(
            "B1: 背景{}秒 トンネル{tun_ok}OK/{tun_ng}NG 直結{loc_ok}OK/{loc_ng}NG",
            started.elapsed().as_secs()
        ));
        if tun_fail_run >= 3 && (!local_ok || loc_ng >= 3) {
            break;
        }
    }
    let bg_secs = started.elapsed().as_secs();

    // B3: bring Probe back (tunnel first, local second).
    status("B3: Probeを前面に戻す");
    let back = match wda_call(&provider, Route::Tunnel, "B3", "POST", &activate_path, &activate_body).await {
        Ok(_) => "B3: トンネル経由で復帰".to_string(),
        Err(e) if local_ok => match wda_call(&provider, Route::Local, "B3L", "POST", &activate_path, &activate_body).await {
            Ok(_) => format!("{e}\nB3: 直結経由で復帰"),
            Err(e2) => format!("{e}\n{e2}\n手でProbeを開いてください"),
        },
        Err(e) => format!("{e}\n手でProbeを開いてください"),
    };
    let _ = wda.delete_session(&session).await;
    Ok(format!(
        "診断版6: 完了\n{}\n背景{bg_secs}秒: トンネル{tun_ok}OK/{tun_ng}NG, 直結{loc_ok}OK/{loc_ng}NG\n画面取得: {}\n{back}",
        notes.join("\n"),
        if shots.is_empty() { "-".to_string() } else { shots.join(" / ") }
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
    status("診断版6: 開始します");
    let spawned = std::thread::Builder::new().name("runner-probe".into()).spawn(move || {
        let result = std::panic::catch_unwind(move || -> Result<(), String> {
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()
                .map_err(|_| "実行環境を作成できません".to_string())?;
            runtime.block_on(async {
                tokio::select! {
                    result = tokio::time::timeout(Duration::from_secs(420), probe(path, host, runner, self_bundle)) =>
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
