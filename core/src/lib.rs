// Phone Runner Probe 診断版7
// 汎用エンジン（tunnel / wda / capture）＋ 診断フロー（このファイル）。
// ゲーム固有の情報はここにも置かない。対象アプリはアプリ側の入力で指定する。
//
// 診断版7:
//  - アプリ一覧モード: 端末のユーザーアプリ名とBundle IDを表示・保存
//  - 前面アプリ観察モード: 対象アプリを前面にし、指定秒数のあいだ
//    端末内MJPEGで画面を受信（fps計測・一定間隔でJPEG保存）し、最後にProbeへ戻る
mod capture;
mod tunnel;
mod wda;

use std::{
    ffi::{CStr, CString, c_char},
    future::Future,
    path::PathBuf,
    sync::{
        Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use idevice::IdeviceError;
use serde_json::json;

static RUNNING: AtomicBool = AtomicBool::new(false);
static STOP: AtomicBool = AtomicBool::new(false);
static STATUS: Mutex<String> = Mutex::new(String::new());
static CONFIG: Mutex<Option<Config>> = Mutex::new(None);

#[derive(Clone, Default)]
struct Config {
    /// Empty: list installed apps only.
    target: String,
    /// This app's Documents directory (frames and lists are saved here).
    documents: String,
    seconds: u64,
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
    tokio::time::timeout(Duration::from_secs(seconds), task)
        .await
        .map_err(|_| format!("{label}: タイムアウト（{seconds}秒）"))?
        .map_err(|e| safe_error(label, e))
}

fn stopped() -> bool {
    STOP.load(Ordering::SeqCst)
}

async fn list_apps(mut t: tunnel::Tunnel, docs: PathBuf) -> Result<String, String> {
    let apps = tunnel::list_user_apps(&mut t).await?;
    let text: String = apps.iter().map(|(name, id)| format!("{name}\t{id}\n")).collect();
    let saved = std::fs::write(docs.join("apps.txt"), &text).is_ok();
    Ok(format!(
        "アプリ一覧（{}件）{}\n{text}",
        apps.len(),
        if saved { "・apps.txtに保存" } else { "" }
    ))
}

/// Observation run. Returns a summary. Runs while the XCTest runner is alive.
async fn observe(t: &tunnel::Tunnel, self_bundle: &str, cfg: &Config) -> Result<String, String> {
    let docs = PathBuf::from(&cfg.documents);
    let frames_dir = docs.join("frames");
    let _ = std::fs::create_dir_all(&frames_dir);
    let mut notes: Vec<String> = Vec::new();

    let mut w = wda::Wda::start(t.provider()).await?;
    notes.push(if w.prefer_local().await { "L1: 端末内直結OK（以後は直結で操作）" } else { "L1: 直結不可（トンネルで操作）" }.into());

    // Smaller, slower MJPEG frames are enough for recognition and cheaper.
    match w
        .settings(json!({"mjpegScalingFactor": 50, "mjpegServerFramerate": 5, "mjpegServerScreenshotQuality": 40}))
        .await
    {
        Ok(()) => notes.push("S1: MJPEG設定（50%・5fps・品質40）".into()),
        Err(e) => notes.push(format!("S1: {e}（既定のまま続行）")),
    }

    status("C0: 対象アプリを前面へ");
    w.activate(&cfg.target).await?;
    tunnel::sleep_secs(3).await;

    let started = tokio::time::Instant::now();
    let total = Duration::from_secs(cfg.seconds);
    let (mut frames, mut bytes, mut saved, mut reconnects) = (0u64, 0u64, 0u32, 0u32);
    let (mut tun_ok, mut tun_ng, mut wda_ok, mut wda_ng) = (0, 0, 0, 0);
    let mut next_save = Duration::ZERO;
    let mut next_check = Duration::from_secs(10);
    let mut fallback_png = false;
    let mut mjpeg: Option<capture::Mjpeg> = None;
    let mut last_error = String::new();

    while started.elapsed() < total && !stopped() {
        let elapsed = started.elapsed();
        // C1: one frame (MJPEG, or full PNG when MJPEG is unavailable).
        let frame: Result<(Vec<u8>, &str), String> = if fallback_png {
            tunnel::sleep_secs(10).await;
            w.screenshot_png().await.map(|b| (b, "png"))
        } else {
            if mjpeg.is_none() {
                match capture::Mjpeg::connect().await {
                    Ok(m) => mjpeg = Some(m),
                    Err(e) => {
                        reconnects += 1;
                        last_error = e;
                        if reconnects >= 3 {
                            fallback_png = true;
                            notes.push(format!("C1: MJPEG不可→PNG取得に切替（{last_error}）"));
                        }
                        tunnel::sleep_secs(2).await;
                        continue;
                    }
                }
            }
            match tokio::time::timeout(Duration::from_secs(10), mjpeg.as_mut().unwrap().next_frame()).await {
                Ok(Ok(f)) => Ok((f, "jpg")),
                Ok(Err(e)) => Err(e),
                Err(_) => Err("MJPEG: 10秒フレームなし".into()),
            }
        };
        match frame {
            Ok((data, ext)) => {
                frames += 1;
                bytes += data.len() as u64;
                if elapsed >= next_save && saved < 20 {
                    if std::fs::write(frames_dir.join(format!("frame_{:03}.{ext}", elapsed.as_secs())), &data).is_ok() {
                        saved += 1;
                    }
                    next_save = elapsed + Duration::from_secs(15);
                }
            }
            Err(e) => {
                last_error = e;
                mjpeg = None;
                reconnects += 1;
                if reconnects >= 10 && !fallback_png {
                    fallback_png = true;
                    notes.push(format!("C1: MJPEG不安定→PNG取得に切替（{last_error}）"));
                }
            }
        }
        // C2: every 10 s check WDA (current route) and the tunnel separately.
        if started.elapsed() >= next_check {
            next_check = started.elapsed() + Duration::from_secs(10);
            if w.status().await.is_ok() { wda_ok += 1 } else { wda_ng += 1 }
            if w.call(wda::Route::Tunnel, "T", "GET", "/status", "", 8).await.is_ok() { tun_ok += 1 } else { tun_ng += 1 }
        }
        let secs = started.elapsed().as_secs_f64().max(0.1);
        status(&format!(
            "C1: 観察中 {:.0}/{}秒\n受信{frames}枚（{:.1}fps, 平均{}KB）保存{saved}枚\nWDA {wda_ok}OK/{wda_ng}NG, トンネル {tun_ok}OK/{tun_ng}NG",
            secs,
            cfg.seconds,
            frames as f64 / secs,
            if frames > 0 { bytes / frames / 1024 } else { 0 }
        ));
    }
    let secs = started.elapsed().as_secs_f64().max(0.1);
    drop(mjpeg);

    status("C3: Probeを前面に戻す");
    let back = match w.activate(self_bundle).await {
        Ok(()) => "C3: Probeへ復帰".to_string(),
        Err(e) => format!("C3: {e}"),
    };
    let _ = w.call(w.route, "終了", "DELETE", &format!("/session/{}", w.session), "", 10).await;
    Ok(format!(
        "診断版7: 完了（{:.0}秒）\n{}\n受信{frames}枚 {:.1}fps 平均{}KB / 再接続{reconnects}回\n保存{saved}枚（ファイル→このiPhone内→Phone Runner Probe→frames）\nWDA {wda_ok}OK/{wda_ng}NG, トンネル {tun_ok}OK/{tun_ng}NG{}\n{back}",
        secs,
        notes.join("\n"),
        frames as f64 / secs,
        if frames > 0 { bytes / frames / 1024 } else { 0 },
        if last_error.is_empty() { String::new() } else { format!("\n最後のエラー: {last_error}") }
    ))
}

async fn probe(path: String, host: String, runner: String, self_bundle: String, cfg: Config) -> Result<String, String> {
    let addr = host.parse::<std::net::IpAddr>().map_err(|_| "接続先IPアドレスが不正です".to_string())?;
    let mut t = tunnel::open(path, addr).await?;
    if cfg.target.is_empty() {
        return list_apps(t, PathBuf::from(&cfg.documents)).await;
    }
    if runner.is_empty() {
        return Err("WDAのBundle IDが未入力です".into());
    }
    let runner_cfg = tunnel::runner_config(&mut t, &runner).await?;
    status("W2: XCTestでWDAを起動中（WDA画面が前面に出る場合があります）");
    tokio::select! {
        message = tunnel::run_wda(&t, runner_cfg) => Err(message),
        result = observe(&t, &self_bundle, &cfg) => result,
    }
}

/// Call before probe_start. target: bundle id of the app to observe (empty =
/// list apps), documents: this app's Documents path, seconds: 30..1800.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn probe_configure(target: *const c_char, documents: *const c_char, seconds: u32) -> bool {
    if target.is_null() || documents.is_null() {
        return false;
    }
    let read = |p: *const c_char| unsafe { CStr::from_ptr(p) }.to_str().map(str::to_owned);
    let (Ok(target), Ok(documents)) = (read(target), read(documents)) else { return false };
    let seconds = (seconds as u64).clamp(30, 1800);
    if let Ok(mut c) = CONFIG.lock() {
        *c = Some(Config { target, documents, seconds });
        return true;
    }
    false
}

/// Copies arguments before returning. `runner` is the WDA xctrunner bundle id,
/// `self_bundle` is this app's bundle id (used to come back to the front).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn probe_start(path: *const c_char, host: *const c_char, runner: *const c_char, self_bundle: *const c_char) -> bool {
    if path.is_null() || host.is_null() || runner.is_null() || self_bundle.is_null() {
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
    let (Ok(path), Ok(host), Ok(runner), Ok(self_bundle)) = (read(path), read(host), read(runner), read(self_bundle)) else {
        RUNNING.store(false, Ordering::SeqCst);
        return false;
    };
    STOP.store(false, Ordering::SeqCst);
    status("診断版7: 開始します");
    let limit = cfg.seconds + 240;
    let spawned = std::thread::Builder::new().name("runner-probe".into()).spawn(move || {
        let result = std::panic::catch_unwind(move || -> Result<String, String> {
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()
                .map_err(|_| "実行環境を作成できません".to_string())?;
            runtime.block_on(async {
                tokio::select! {
                    result = tokio::time::timeout(Duration::from_secs(limit), probe(path, host, runner, self_bundle, cfg)) =>
                        result.map_err(|_| "試験全体がタイムアウトしました".to_string())?,
                    _ = async { while !stopped() { tokio::time::sleep(Duration::from_millis(100)).await; } } =>
                        Ok("停止しました".to_string()),
                }
            })
        });
        match result {
            Ok(Ok(message)) => status(&message),
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
