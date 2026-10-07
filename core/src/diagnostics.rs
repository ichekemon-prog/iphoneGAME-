//! Bounded, on-demand diagnostics. No AI, taps, or pairing secrets in the report.
use std::{future::Future, sync::Mutex, time::Duration};
use serde_json::{Value, json};
use crate::{capture, tunnel, wda};

static REPORT: Mutex<Option<Value>> = Mutex::new(None);

pub fn reset(enabled: bool) {
    if let Ok(mut report) = REPORT.lock() {
        *report = if enabled { Some(json!({"state":"running", "rows":[], "summary":"接続診断中"})) } else { None };
    }
}

pub fn record(id: &str, state: &str, detail: &str) {
    if let Ok(mut report) = REPORT.lock() {
        if let Some(rows) = report.as_mut().and_then(|r| r["rows"].as_array_mut()) {
            let row = json!({"id":id,"state":state,"detail":detail,"hint":hint(id)});
            if let Some(old) = rows.iter_mut().find(|r| r["id"].as_str() == Some(id)) { *old = row; }
            else { rows.push(row); }
        }
    }
}

pub fn finish(state: &str, summary: &str) {
    if let Ok(mut report) = REPORT.lock() {
        if let Some(r) = report.as_mut() {
            r["state"] = json!(state);
            r["summary"] = json!(summary);
            if let Some(rows) = r["rows"].as_array_mut() {
                for row in rows {
                    if row["state"] == "running" {
                        row["state"] = json!(if state == "cancelled" { "cancelled" } else { "failed" });
                        row["detail"] = json!(summary);
                    }
                }
            }
        }
    }
}

pub fn snapshot() -> String {
    REPORT.lock().ok().and_then(|r| r.clone()).unwrap_or(json!({"state":"idle","rows":[],"summary":"未実施"})).to_string()
}

fn hint(id: &str) -> &'static str {
    match id.split(':').next().unwrap_or(id) {
        "R0" => "このiPhoneのRemote Pairingファイルを読み込み直してください。",
        "R1" | "R5" => "LocalDevVPNの接続とDevice IPを確認してください。VPN状態そのものを判定した結果ではありません。",
        "R2" | "R3" => "端末のロックを解除し、この端末用の認証ファイルか確認してください。解消しなければ再ペアリングを確認します。",
        "R4" | "R6" | "R7" | "R8" => "VPNを再接続して診断をやり直してください。直らない場合はこの診断結果を保存してください。",
        "DDI" | "D0" => "『開発用ディスクイメージを準備』でファイルを取得してから、もう一度診断してください。開発者モードがONかも確認してください。",
        "D1" | "D2" | "D3" | "D4" => "インターネットに接続できるか（Appleの署名サーバーへの通信が必要）を確認し、もう一度診断してください。直らない場合はこの結果を保存してください。",
        "W0" => "WDAをインストールしてから、もう一度診断してください（PCでの導入が必要です）。",
        "A1" | "A2" => "VPNを再接続して診断をやり直してください。",
        "W1" => "WDAのインストール状態とBundle IDを確認してください。",
        "WDA" => "WDAの署名期限・開発者モード・開発用サービスを確認してください。",
        "LOCAL" | "FRAME" => "WDAを起動し直して再診断してください。接続先は端末内の8100/9100ポートです。",
        _ => "設定を確認して診断をやり直してください。",
    }
}

async fn check<T>(id: &str, seconds: u64, task: impl Future<Output = Result<T, String>>) -> Result<T, String> {
    record(id, "running", "確認中");
    let result = tokio::time::timeout(Duration::from_secs(seconds), task).await
        .map_err(|_| format!("{id}: タイムアウト（{seconds}秒）")).and_then(|r| r);
    match &result {
        Ok(_) => record(id, "passed", "確認できました"),
        Err(e) => record(id, "failed", e),
    }
    result
}

pub async fn run(mut t: tunnel::Tunnel, runner: &str, ddi_dir: &str) -> Result<String, String> {
    // Presence is evidence of service advertisement, not proof of a mounted DDI.
    let testmanager = crate::ddi::has_testmanager(&t.handshake);
    let instruments = t.handshake.services.keys().any(|name| name.contains("dtservicehub"));
    if testmanager {
        record("DDI", "passed", &format!("開発用サービスの広告: testmanagerd=true / dtservicehub={instruments}"));
    } else {
        record("DDI", "running", "testmanagerdが見つかりません。開発用ディスクイメージのマウントを試みます（再起動後に必要）");
        match crate::ddi::ensure(&mut t, ddi_dir).await {
            Ok(_) => record("DDI", "passed", "開発用ディスクイメージをマウントし、testmanagerdを確認しました"),
            Err(e) => {
                record("DDI", "failed", &e);
                return Err(e);
            }
        }
    }
    if runner.trim().is_empty() {
        record("W1", "failed", "WDAのBundle IDが未入力です");
        return Err("WDAのBundle IDを入力してください".into());
    }
    let config = tunnel::runner_config(&mut t, runner).await?;
    record("WDA", "running", "XCTest起動とWDAセッションを確認中（WDA画面に切り替わる場合があります）");
    tokio::select! {
        message = tunnel::run_wda(&t, config) => {
            record("WDA", "failed", &message);
            Err(message)
        },
        result = async {
            let mut w = check("WDA", 100, wda::Wda::start(t.provider())).await?;
            let result = async {
                check("LOCAL", 10, async {
                    if w.prefer_local().await { Ok(()) }
                    else { Err("端末内WDAへの直接接続を確認できませんでした".into()) }
                }).await?;
                check("FRAME", 20, async {
                    let mut stream = capture::Mjpeg::connect().await?;
                    let bytes = stream.next_frame().await?;
                    if bytes.len() < 4 || !bytes.starts_with(&[0xff, 0xd8]) || !bytes.ends_with(&[0xff, 0xd9]) {
                        return Err("MJPEGのJPEGマーカーが不正です".into());
                    }
                    // Do not retain or export the screenshot.
                    Ok(())
                }).await?;
                Ok("接続診断完了：WDAセッション・端末内接続・JPEG受信を確認。AI判断とタップは未実施。".to_string())
            }.await;
            let _ = w.call(w.route, "診断終了", "DELETE", &format!("/session/{}", w.session), "", 5).await;
            result
        } => result,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn keeps_failure_and_marks_interrupted_checks_without_claiming_success() {
        reset(true);
        record("R0: 認証", "passed", "確認済み");
        record("R1: 到達", "running", "確認中");
        finish("cancelled", "停止しました");
        let report: Value = serde_json::from_str(&snapshot()).unwrap();
        assert_eq!(report["rows"][0]["state"], "passed");
        assert_eq!(report["rows"][1]["state"], "cancelled");
        reset(true);
        record("R3: 認証", "failed", "認証失敗");
        finish("failed", "終了");
        let report: Value = serde_json::from_str(&snapshot()).unwrap();
        assert_eq!(report["rows"].as_array().unwrap().len(), 1);
        assert_eq!(report["rows"][0]["detail"], "認証失敗");
        reset(false);
        record("R0", "passed", "通常起動");
        assert_eq!(serde_json::from_str::<Value>(&snapshot()).unwrap()["state"], "idle");
    }
}
