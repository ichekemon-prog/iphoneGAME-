use std::{ffi::{c_char, CStr, CString}, future::Future, sync::{Mutex, atomic::{AtomicBool, Ordering}}, time::Duration};
use idevice::{IdeviceError, remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native}, rsd::RsdHandshake, tcp::adapter::Adapter};
static RUNNING: AtomicBool = AtomicBool::new(false);
static STOP: AtomicBool = AtomicBool::new(false);
static CELLULAR_RESTORED: AtomicBool = AtomicBool::new(false);
static HOLDING: AtomicBool = AtomicBool::new(false);
static STATUS: Mutex<String> = Mutex::new(String::new());
fn status(value: &str) { if let Ok(mut s) = STATUS.lock() { *s = value.into(); } }
// Only numeric error codes and OS error kinds may leave the library.
fn safe_error(stage: &str, error: IdeviceError) -> String {
    let mut detail = format!("{stage}: 失敗 code={} sub={}", error.code(), error.sub_code());
    if let IdeviceError::Socket(io) = &error {
        detail.push_str(&format!(" io={:?} os={:?}", io.kind(), io.raw_os_error()));
    }
    detail
}
async fn step<T>(label: &str, seconds: u64, task: impl Future<Output = Result<T, IdeviceError>>) -> Result<T, String> {
    status(label);
    tokio::time::timeout(Duration::from_secs(seconds), task).await
        .map_err(|_| format!("{label}: タイムアウト（{seconds}秒）"))?
        .map_err(|e| safe_error(label, e))
}
async fn probe(path: String, host: String) -> Result<(), String> {
    let addr = host.parse::<std::net::IpAddr>().map_err(|_| "接続先IPアドレスが不正です".to_string())?;
    let mut pairing = step("R0: 保存済みRemote Pairing情報を確認", 5, RpPairingFile::read_from_file(path)).await?;
    let stream = step("R1: 接続先49152へ接続", 10, async {
        Ok(tokio::net::TcpStream::connect((addr, 49152)).await?)
    }).await?;
    let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), "PhoneRunnerProbe");
    // connect() would fall back to fresh pairing. Verify existing keys only.
    step("R2: Remote Pairingの応答を確認", 15, rpc.attempt_pair_verify()).await?;
    step("R3: 保存済み認証情報で認証", 15, rpc.validate_pairing(&mut pairing)).await?;
    let port = step("R4: 通信経路を要求", 15, rpc.create_tcp_listener()).await?;
    if port == 0 { return Err("R4: 無効な接続ポート".into()); }
    let stream = step("R5: 通信経路へ接続", 10, async {
        Ok(tokio::net::TcpStream::connect((addr, port)).await?)
    }).await?;
    let tunnel = step("R6: 暗号化・トンネル確立", 20,
        connect_tls_psk_tunnel_native(stream, rpc.encryption_key())).await?;
    let client_ip = tunnel.info.client_address.parse::<std::net::IpAddr>()
        .map_err(|_| "R6: クライアントIPの形式が不正".to_string())?;
    let server_ip = tunnel.info.server_address.parse::<std::net::IpAddr>()
        .map_err(|_| "R6: サーバーIPの形式が不正".to_string())?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;
    if rsd_port == 0 || mtu <= 60 { return Err("R6: トンネル設定が不正".into()); }
    let mut adapter = Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = adapter.to_async_handle();
    let stream = step("R7: サービス確認先へ接続", 15, async {
        adapter.connect(rsd_port).await.map_err(IdeviceError::Socket)
    }).await?;
    let handshake = step("R8: 利用可能なサービスを確認", 15, RsdHandshake::new(stream)).await?;
    if handshake.services.is_empty() { return Err("R8: 応答はありましたがサービス一覧が空です".into()); }
    HOLDING.store(true, Ordering::SeqCst);
    status(&format!("診断版4: 接続成功（{}サービス）。120秒の維持試験中。\n機内モードをOFFにし、4G/5G表示に戻ったら下の『携帯通信を戻しました』を押してください。", handshake.services.len()));
    let started = tokio::time::Instant::now();
    let mut checks = 0;
    let mut after_restore = 0;
    while started.elapsed() < Duration::from_secs(120) {
        tokio::time::sleep(Duration::from_secs(5)).await;
        let marked = CELLULAR_RESTORED.load(Ordering::SeqCst);
        // Reuse the same outer TCP/TLS tunnel. Only the RSD stream inside it is
        // reopened. Never reconnect the tunnel or repeat pairing on failure.
        let reply = tokio::time::timeout(Duration::from_secs(8), async {
            let stream = adapter.connect(rsd_port).await.map_err(IdeviceError::Socket)?;
            RsdHandshake::new(stream).await
        }).await;
        let failure = match reply {
            Ok(Ok(reply)) if !reply.services.is_empty() => None,
            Ok(Ok(_)) => Some("サービス一覧が空です".to_string()),
            Ok(Err(e)) => Some(safe_error("H1: 既存トンネルの応答確認", e)),
            Err(_) => Some("H1: 既存トンネルの応答が8秒以内にありません".to_string()),
        };
        if let Some(error) = failure {
            return Err(format!("診断版4: 維持試験停止（{}秒）\n{error}\n応答成功{checks}回 / 携帯通信復帰の申告後{after_restore}回。自動再接続はしていません。", started.elapsed().as_secs()));
        }
        checks += 1;
        if marked { after_restore += 1; }
        let instruction = if CELLULAR_RESTORED.load(Ordering::SeqCst) {
            "復帰の申告を受け付けました。この画面のままお待ちください。"
        } else {
            "機内モードをOFFにし、4G/5G表示に戻ったら『携帯通信を戻しました』を押してください。"
        };
        status(&format!("診断版4: 既存トンネルの応答あり（{}秒）\n応答成功{checks}回 / 復帰の申告後{after_restore}回\n{instruction}", started.elapsed().as_secs()));
    }
    let conclusion = if after_restore > 0 {
        "復帰の申告後も既存トンネルから応答を取得しました。"
    } else {
        "携帯通信復帰後の確認は未完了です。"
    };
    status(&format!("診断版4: 維持試験終了\n応答成功{checks}回 / 復帰の申告後{after_restore}回\n{conclusion}\nゲーム通信・WDA操作・長時間維持は未検証です。"));
    Ok(())
}
/// Arguments are copied before return. bundle is retained for ABI compatibility.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn probe_start(path: *const c_char, host: *const c_char, _bundle: *const c_char) -> bool {
    if path.is_null() || host.is_null() { return false; }
    if RUNNING.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).is_err() { return false; }
    let values = unsafe { (CStr::from_ptr(path).to_str(), CStr::from_ptr(host).to_str()) };
    let (Ok(path), Ok(host)) = values else { RUNNING.store(false, Ordering::SeqCst); return false; };
    let (path, host) = (path.to_owned(), host.to_owned());
    STOP.store(false, Ordering::SeqCst);
    CELLULAR_RESTORED.store(false, Ordering::SeqCst);
    HOLDING.store(false, Ordering::SeqCst);
    status("診断版4: 接続試験を開始します");
    let spawned = std::thread::Builder::new().name("runner-probe".into()).spawn(move || {
        let result = std::panic::catch_unwind(|| -> Result<(), String> {
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()
                .map_err(|_| "実行環境を作成できません".to_string())?;
            runtime.block_on(async {
                tokio::select! {
                    result = tokio::time::timeout(Duration::from_secs(270), probe(path, host)) =>
                        result.map_err(|_| "試験全体がタイムアウトしました".to_string())?,
                    _ = async { while !STOP.load(Ordering::SeqCst) { tokio::time::sleep(Duration::from_millis(100)).await; } } => {
                        status("停止しました"); Ok(())
                    }
                }
            })
        });
        match result { Ok(Ok(())) => {}, Ok(Err(e)) => status(&e), Err(_) => status("内部エラーで停止しました") }
        HOLDING.store(false, Ordering::SeqCst);
        RUNNING.store(false, Ordering::SeqCst);
    });
    if spawned.is_err() { RUNNING.store(false, Ordering::SeqCst); status("処理を開始できません"); return false; }
    true
}
#[unsafe(no_mangle)] pub extern "C" fn probe_stop() { STOP.store(true, Ordering::SeqCst); }
#[unsafe(no_mangle)] pub extern "C" fn probe_running() -> bool { RUNNING.load(Ordering::SeqCst) }
#[unsafe(no_mangle)] pub extern "C" fn probe_holding() -> bool { HOLDING.load(Ordering::SeqCst) }
#[unsafe(no_mangle)] pub extern "C" fn probe_mark_cellular_restored() {
    if HOLDING.load(Ordering::SeqCst) { CELLULAR_RESTORED.store(true, Ordering::SeqCst); }
}
#[unsafe(no_mangle)] pub extern "C" fn probe_status() -> *mut c_char {
    let s = STATUS.lock().map(|s| s.clone()).unwrap_or_else(|_| "状態取得エラー".into());
    CString::new(s).unwrap_or_default().into_raw()
}
#[unsafe(no_mangle)] pub unsafe extern "C" fn probe_free_string(p: *mut c_char) {
    if !p.is_null() { drop(unsafe { CString::from_raw(p) }); }
}
