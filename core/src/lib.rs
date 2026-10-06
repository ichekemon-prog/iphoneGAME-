// Phone Runner Probe 診断版8
// 汎用エンジン（tunnel / wda / capture）＋ 「目と手」のサービス。
// AIの判断（頭脳）はSwift側。ここは「最新の画面を渡す」「指示された操作をする」だけ。
// ゲーム固有の情報は置かない。
//
//  - アプリ一覧モード: target が空のとき、ユーザーアプリ名とBundle IDを表示・保存
//  - エージェントモード: WDAを起動して対象アプリを前面にし、
//    端末内MJPEGで最新画面を保持しながら、Swiftからの操作コマンドを実行する
mod capture;
mod diagnostics;
mod tunnel;
mod wda;

use std::{
    ffi::{CStr, CString, c_char},
    future::Future,
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc as std_mpsc,
    },
    time::Duration,
};

use idevice::IdeviceError;
use serde_json::{Value, json};
use tokio::sync::mpsc;

static RUNNING: AtomicBool = AtomicBool::new(false);
static READY: AtomicBool = AtomicBool::new(false);
static STOP: AtomicBool = AtomicBool::new(false);
static STATUS: Mutex<String> = Mutex::new(String::new());
static CONFIG: Mutex<Option<Config>> = Mutex::new(None);
static FRAME: Mutex<Option<Arc<Vec<u8>>>> = Mutex::new(None);
static FRAME_SEQ: AtomicU64 = AtomicU64::new(0);
static COMMANDS: Mutex<Option<mpsc::UnboundedSender<(String, std_mpsc::Sender<String>)>>> = Mutex::new(None);

#[derive(Clone, Default)]
struct Config {
    /// Empty: list installed apps only.
    target: String,
    /// This app's Documents directory.
    documents: String,
    /// Upper limit of one agent session.
    seconds: u64,
    diagnostic: bool,
}

pub(crate) fn status(value: &str) {
    if let Ok(mut s) = STATUS.lock() {
        *s = value.into();
    }
}

// Only numeric error codes and OS error kinds may leave the library.
pub(crate) fn safe_error(stage: &str, error: IdeviceError) -> String {
    let mut detail = format!("{stage}: 失敗 code={} sub={}", error.code(), error.sub_code());
    if let IdeviceError::Socket(io) = &error {
        detail.push_str(&format!(" io={:?} os={:?}", io.kind(), io.raw_os_error()));
    }
    detail
}

pub(crate) async fn step<T>(label: &str, seconds: u64, task: impl Future<Output = Result<T, IdeviceError>>) -> Result<T, String> {
    status(label);
    diagnostics::record(label, "running", "確認中");
    let result = tokio::time::timeout(Duration::from_secs(seconds), task)
        .await
        .map_err(|_| format!("{label}: タイムアウト（{seconds}秒）"))
        .and_then(|r| r.map_err(|e| safe_error(label, e)));
    match &result {
        Ok(_) => diagnostics::record(label, "passed", "確認できました"),
        Err(e) => diagnostics::record(label, "failed", e),
    }
    result
}

fn stopped() -> bool {
    STOP.load(Ordering::SeqCst)
}

async fn list_apps(mut t: tunnel::Tunnel, docs: PathBuf) -> Result<String, String> {
    let apps = tunnel::list_user_apps(&mut t).await?;
    let text: String = apps.iter().map(|(name, id)| format!("{name}\t{id}\n")).collect();
    let saved = std::fs::write(docs.join("apps.txt"), &text).is_ok();
    Ok(format!("アプリ一覧（{}件）{}\n{text}", apps.len(), if saved { "・apps.txtに保存" } else { "" }))
}

fn num(v: &Value, key: &str) -> Option<f64> {
    v.get(key).and_then(|x| x.as_f64())
}

/// Executes one command from the agent. Coordinates are normalized 0..1000
/// (x from the left, y from the top) and converted to screen points here.
async fn execute(w: &wda::Wda, size: (f64, f64), command: &str) -> String {
    let Ok(v) = serde_json::from_str::<Value>(command) else { return "error: JSONが不正".into() };
    let to_pt = |nx: f64, ny: f64| ((nx.clamp(0.0, 1000.0) / 1000.0) * size.0, (ny.clamp(0.0, 1000.0) / 1000.0) * size.1);
    let result = match v.get("type").and_then(|t| t.as_str()).unwrap_or("") {
        "tap" => match (num(&v, "x"), num(&v, "y")) {
            (Some(x), Some(y)) => {
                let (px, py) = to_pt(x, y);
                w.tap(px, py).await
            }
            _ => Err("tap: x/yがありません".into()),
        },
        "swipe" => match (num(&v, "x"), num(&v, "y"), num(&v, "x2"), num(&v, "y2")) {
            (Some(x), Some(y), Some(x2), Some(y2)) => {
                let (a, b) = to_pt(x, y);
                let (c, d) = to_pt(x2, y2);
                let ms = num(&v, "ms").unwrap_or(400.0).clamp(50.0, 3000.0) as u64;
                w.swipe(a, b, c, d, ms).await
            }
            _ => Err("swipe: 座標がありません".into()),
        },
        "activate" => match v.get("bundle").and_then(|b| b.as_str()) {
            Some(b) => w.activate(b).await,
            None => Err("activate: bundleがありません".into()),
        },
        "home" => w.home().await,
        "status" => w.status().await,
        other => Err(format!("未対応のコマンド: {other}")),
    };
    match result {
        Ok(()) => "ok".into(),
        Err(e) => format!("error: {e}"),
    }
}

/// Agent service: keeps the latest screen frame and executes commands.
async fn service(t: &tunnel::Tunnel, cfg: &Config, mut rx: mpsc::UnboundedReceiver<(String, std_mpsc::Sender<String>)>) -> Result<String, String> {
    let mut w = wda::Wda::start(t.provider()).await?;
    let local = w.prefer_local().await;
    if let Err(e) = w
        .settings(json!({"mjpegScalingFactor": 50, "mjpegServerFramerate": 5, "mjpegServerScreenshotQuality": 40}))
        .await
    {
        status(&format!("S1: {e}（既定のまま続行）"));
    }
    let size = w.window_size().await?;
    status("C0: 対象アプリを前面へ");
    w.activate(&cfg.target).await?;

    let started = tokio::time::Instant::now();
    let limit = Duration::from_secs(cfg.seconds);
    let mut mjpeg: Option<capture::Mjpeg> = None;
    let (mut frames, mut commands, mut reconnects) = (0u64, 0u64, 0u32);
    let mut last_error = String::new();
    READY.store(true, Ordering::SeqCst);
    let mut tick = tokio::time::interval(Duration::from_secs(1));

    while started.elapsed() < limit && !stopped() {
        if mjpeg.is_none() {
            match capture::Mjpeg::connect().await {
                Ok(m) => mjpeg = Some(m),
                Err(e) => {
                    reconnects += 1;
                    last_error = e;
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    continue;
                }
            }
        }
        let m = mjpeg.as_mut().unwrap();
        tokio::select! {
            frame = m.next_frame() => match frame {
                Ok(f) => {
                    frames += 1;
                    if let Ok(mut slot) = FRAME.lock() { *slot = Some(Arc::new(f)); }
                    FRAME_SEQ.fetch_add(1, Ordering::SeqCst);
                }
                Err(e) => { last_error = e; mjpeg = None; reconnects += 1; }
            },
            cmd = rx.recv() => match cmd {
                Some((command, reply)) => {
                    commands += 1;
                    let _ = reply.send(execute(&w, size, &command).await);
                }
                None => break,
            },
            _ = tick.tick() => {
                status(&format!(
                    "エージェント接続中 {}秒 / 画面{frames}枚 / 操作{commands}回 / 再接続{reconnects}回\n画面サイズ {:.0}x{:.0}pt・{}{}",
                    started.elapsed().as_secs(), size.0, size.1,
                    if local { "端末内直結" } else { "トンネル経由" },
                    if last_error.is_empty() { String::new() } else { format!("\n最後のエラー: {last_error}") }
                ));
            }
        }
    }
    READY.store(false, Ordering::SeqCst);
    let _ = w.call(w.route, "終了", "DELETE", &format!("/session/{}", w.session), "", 10).await;
    Ok(format!(
        "エージェント接続終了（{}秒）画面{frames}枚 / 操作{commands}回 / 再接続{reconnects}回",
        started.elapsed().as_secs()
    ))
}

async fn probe(path: String, host: String, runner: String, cfg: Config) -> Result<String, String> {
    let addr = host.parse::<std::net::IpAddr>().map_err(|_| "接続先IPアドレスが不正です".to_string())?;
    let mut t = tunnel::open(path, addr).await?;
    if cfg.diagnostic {
        return diagnostics::run(t, &runner).await;
    }
    if cfg.target.is_empty() {
        return list_apps(t, PathBuf::from(&cfg.documents)).await;
    }
    if runner.is_empty() {
        return Err("WDAのBundle IDが未入力です".into());
    }
    let runner_cfg = tunnel::runner_config(&mut t, &runner).await?;
    let (tx, rx) = mpsc::unbounded_channel();
    if let Ok(mut c) = COMMANDS.lock() {
        *c = Some(tx);
    }
    status("W2: XCTestでWDAを起動中（WDA画面が前面に出る場合があります）");
    let result = tokio::select! {
        message = tunnel::run_wda(&t, runner_cfg) => Err(message),
        result = service(&t, &cfg, rx) => result,
    };
    if let Ok(mut c) = COMMANDS.lock() {
        *c = None;
    }
    result
}

/// Call before probe_start. target: bundle id of the app to operate (empty =
/// list apps), documents: this app's Documents path, seconds: session limit.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn probe_configure(target: *const c_char, documents: *const c_char, seconds: u32) -> bool {
    if target.is_null() || documents.is_null() {
        return false;
    }
    let read = |p: *const c_char| unsafe { CStr::from_ptr(p) }.to_str().map(str::to_owned);
    let (Ok(target), Ok(documents)) = (read(target), read(documents)) else { return false };
    let seconds = (seconds as u64).clamp(30, 7200);
    if let Ok(mut c) = CONFIG.lock() {
        *c = Some(Config { target, documents, seconds, diagnostic: false });
        return true;
    }
    false
}

/// Copies arguments before returning. `runner` is the WDA xctrunner bundle id.
/// `_self_bundle` is kept for ABI compatibility.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn probe_start(path: *const c_char, host: *const c_char, runner: *const c_char, _self_bundle: *const c_char) -> bool {
    if path.is_null() || host.is_null() || runner.is_null() {
        return false;
    }
    let Some(cfg) = CONFIG.lock().ok().and_then(|c| c.clone()) else {
        status("設定が未指定です");
        return false;
    };
    if RUNNING.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).is_err() {
        return false;
    }
    let read = |p: *const c_char| unsafe { CStr::from_ptr(p) }.to_str().map(str::to_owned);
    let (Ok(path), Ok(host), Ok(runner)) = (read(path), read(host), read(runner)) else {
        RUNNING.store(false, Ordering::SeqCst);
        return false;
    };
    STOP.store(false, Ordering::SeqCst);
    READY.store(false, Ordering::SeqCst);
    diagnostics::reset(cfg.diagnostic);
    if let Ok(mut f) = FRAME.lock() {
        *f = None;
    }
    status("診断版8: 開始します");
    let limit = cfg.seconds + 240;
    let spawned = std::thread::Builder::new().name("runner-probe".into()).spawn(move || {
        let result = std::panic::catch_unwind(move || -> Result<String, String> {
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()
                .map_err(|_| "実行環境を作成できません".to_string())?;
            runtime.block_on(async {
                tokio::select! {
                    result = tokio::time::timeout(Duration::from_secs(limit), probe(path, host, runner, cfg)) =>
                        result.map_err(|_| "全体の制限時間に達しました".to_string())?,
                    _ = async { while !stopped() { tokio::time::sleep(Duration::from_millis(100)).await; } } =>
                        Ok("停止しました".to_string()),
                }
            })
        });
        READY.store(false, Ordering::SeqCst);
        if let Ok(mut c) = COMMANDS.lock() {
            *c = None;
        }
        match result {
            Ok(Ok(message)) => {
                diagnostics::finish(if stopped() { "cancelled" } else { "passed" }, &message);
                status(&message);
            }
            Ok(Err(e)) => { diagnostics::finish("failed", &e); status(&e); }
            Err(_) => {
                diagnostics::finish("failed", "内部エラーで停止しました");
                status("内部エラーで停止しました");
            }
        }
        RUNNING.store(false, Ordering::SeqCst);
    });
    if spawned.is_err() {
        RUNNING.store(false, Ordering::SeqCst);
        diagnostics::finish("failed", "処理を開始できません");
        status("処理を開始できません");
        return false;
    }
    true
}

/// Select bounded diagnostics after configure and before start.
#[unsafe(no_mangle)]
pub extern "C" fn probe_enable_diagnostics() -> bool {
    if RUNNING.load(Ordering::SeqCst) { return false; }
    if let Ok(mut config) = CONFIG.lock() {
        if let Some(c) = config.as_mut() { c.diagnostic = true; c.seconds = 60; return true; }
    }
    false
}

/// Caller frees with probe_free_string. Contains no raw pairing/service data.
#[unsafe(no_mangle)]
pub extern "C" fn probe_diagnostics() -> *mut c_char {
    CString::new(diagnostics::snapshot()).unwrap_or_default().into_raw()
}

/// True while WDA is up, the target app was brought to the front and frames
/// and commands are being served.
#[unsafe(no_mangle)]
pub extern "C" fn agent_ready() -> bool {
    READY.load(Ordering::SeqCst)
}

/// Increments every time a new frame arrives.
#[unsafe(no_mangle)]
pub extern "C" fn agent_frame_seq() -> u64 {
    FRAME_SEQ.load(Ordering::SeqCst)
}

/// Copies the latest JPEG frame. Returns null when none. Free with agent_free_frame.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agent_copy_frame(len_out: *mut usize) -> *mut u8 {
    if len_out.is_null() {
        return std::ptr::null_mut();
    }
    let Some(frame) = FRAME.lock().ok().and_then(|f| f.clone()) else { return std::ptr::null_mut() };
    let boxed: Box<[u8]> = frame.as_slice().into();
    unsafe { *len_out = boxed.len() };
    Box::into_raw(boxed) as *mut u8
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn agent_free_frame(p: *mut u8, len: usize) {
    if !p.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, len)) });
    }
}

/// Runs one command (JSON, see execute()) and blocks until it finishes
/// (max 30 s). Returns "ok" or "error: ...". Free with probe_free_string.
/// Do not call from the main thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agent_command(json: *const c_char) -> *mut c_char {
    let answer = (|| {
        if json.is_null() {
            return "error: 空のコマンド".to_string();
        }
        let Ok(command) = unsafe { CStr::from_ptr(json) }.to_str().map(str::to_owned) else {
            return "error: 文字コードが不正".to_string();
        };
        let Some(tx) = COMMANDS.lock().ok().and_then(|c| c.clone()) else {
            return "error: エージェント接続がありません".to_string();
        };
        let (reply_tx, reply_rx) = std_mpsc::channel();
        if tx.send((command, reply_tx)).is_err() {
            return "error: エージェント接続が終了しています".to_string();
        }
        reply_rx.recv_timeout(Duration::from_secs(30)).unwrap_or_else(|_| "error: 30秒以内に応答なし".to_string())
    })();
    CString::new(answer).unwrap_or_default().into_raw()
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
