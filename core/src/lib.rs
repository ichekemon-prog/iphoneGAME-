use std::{ffi::{c_char, CStr, CString}, sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}}, time::Duration};
use idevice::{IdeviceService, pairing_file::PairingFile, provider::{IdeviceProvider, TcpProvider}, services::{installation_proxy::InstallationProxyClient, wda::WdaClient, dvt::xctest::{TestConfig, XCUITestService}}};

static RUNNING: AtomicBool = AtomicBool::new(false);
static STOP: AtomicBool = AtomicBool::new(false);
static STATUS: Mutex<String> = Mutex::new(String::new());

fn status(value: &str) { if let Ok(mut s) = STATUS.lock() { *s = value.into(); } }

// Deliberately omit raw errors: pairing records and identifiers must not enter logs.
async fn probe(path: String, host: String, bundle: String) -> Result<(), &'static str> {
    status("1/4: TCP 62078への接続を確認中");
    let addr = host.parse::<std::net::IpAddr>().map_err(|_| "IPアドレスが不正です")?;
    tokio::time::timeout(Duration::from_secs(8), tokio::net::TcpStream::connect((addr, 62078)))
        .await.map_err(|_| "TCP接続がタイムアウト。VPN経路を確認してください")?
        .map_err(|_| "TCP接続不可。この経路では起動できません")?;
    let pairing = PairingFile::read_from_file(path).map_err(|_| "通常のペアリングファイルを読み込めません（Remote Pairing形式は非対応）")?;
    let provider: Arc<dyn IdeviceProvider> = Arc::new(TcpProvider {
        addr, scope_id: None, pairing_file: pairing, label: "PhoneRunnerProbe".into()
    });
    status("2/4: ペアリング認証・インストール済みRunnerを確認中");
    let mut proxy = InstallationProxyClient::connect(provider.as_ref()).await
        .map_err(|_| "認証またはアプリ情報の取得に失敗。ペアリング経路の検証が必要です")?;
    let cfg = TestConfig::from_installation_proxy(&mut proxy, &bundle, None).await
        .map_err(|_| "Runner情報を取得できません。署名後のBundle IDを確認してください")?;
    drop(proxy);
    status("3/4: XCTestを起動中（開発用イメージが必要）");
    let service = XCUITestService::new(provider.clone());
    let handle = service.run_until_wda_ready_with_bridge(cfg, Duration::from_secs(30)).await
        .map_err(|_| "XCTest起動またはWDA応答に失敗。DDI・接続経路・署名を確認してください")?;
    status("4/4: WDA応答確認済み。5分間の維持試験中（周回処理なし）");
    // The bridge is owned by handle; dropping it closes its listeners.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(300);
    let client = WdaClient::new(provider.as_ref());
    let mut samples = 0;
    while !STOP.load(Ordering::SeqCst) && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_secs(5)).await;
        match tokio::time::timeout(Duration::from_secs(5), client.status()).await {
            Ok(Ok(reply)) if reply.get("value").and_then(|v| v.get("ready")).and_then(|v| v.as_bool()) == Some(true) => {
                samples += 1;
                status(&format!("4/4: WDA応答を継続確認（{}回）。周回処理なし", samples));
            }
            _ => { handle.abort(); return Err("WDA応答が途切れました。維持試験を停止しました"); }
        }
    }
    handle.abort();
    status("維持試験を終了しました");
    Ok(())
}

/// Arguments are copied before return. Called only with non-null Swift C strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn probe_start(path: *const c_char, host: *const c_char, bundle: *const c_char) -> bool {
    if path.is_null() || host.is_null() || bundle.is_null() { return false; }
    if RUNNING.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).is_err() { return false; }
    let values = unsafe { (CStr::from_ptr(path).to_str(), CStr::from_ptr(host).to_str(), CStr::from_ptr(bundle).to_str()) };
    let (Ok(path), Ok(host), Ok(bundle)) = values else { RUNNING.store(false, Ordering::SeqCst); return false; };
    let (path, host, bundle) = (path.to_owned(), host.to_owned(), bundle.to_owned());
    STOP.store(false, Ordering::SeqCst);
    status("接続試験を開始します");
    let spawned = std::thread::Builder::new().name("runner-probe".into()).spawn(move || {
        let result = std::panic::catch_unwind(|| {
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()
                .map_err(|_| "実行環境を作成できません")?;
            runtime.block_on(async {
                tokio::select! {
                    result = tokio::time::timeout(Duration::from_secs(360), probe(path,host,bundle)) =>
                        result.map_err(|_| "試験全体がタイムアウトしました")?,
                    _ = async { while !STOP.load(Ordering::SeqCst) { tokio::time::sleep(Duration::from_millis(200)).await; } } => {
                        status("停止しました"); Ok(())
                    }
                }
            })
        });
        match result { Ok(Ok(())) => {}, Ok(Err(e)) => status(e), Err(_) => status("内部エラーで停止しました") }
        RUNNING.store(false,Ordering::SeqCst);
    });
    if spawned.is_err() { RUNNING.store(false,Ordering::SeqCst); status("処理を開始できません"); return false; }
    true
}

#[unsafe(no_mangle)] pub extern "C" fn probe_stop() { STOP.store(true,Ordering::SeqCst); }
#[unsafe(no_mangle)] pub extern "C" fn probe_running() -> bool { RUNNING.load(Ordering::SeqCst) }
#[unsafe(no_mangle)] pub extern "C" fn probe_status() -> *mut c_char {
    let s = STATUS.lock().map(|s| s.clone()).unwrap_or_else(|_| "状態取得エラー".into());
    CString::new(s).unwrap_or_default().into_raw()
}
#[unsafe(no_mangle)] pub unsafe extern "C" fn probe_free_string(p: *mut c_char) {
    if !p.is_null() { drop(unsafe { CString::from_raw(p) }); }
}
