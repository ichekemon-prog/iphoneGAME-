#![allow(dead_code)] // engine API: some calls are used by later versions
//! Engine: minimal WDA client using WDA's own endpoints (no Appium "mobile:"
//! scripts, which plain WDA rejects). Game independent.
use std::time::Duration;

use base64::{Engine as _, engine::general_purpose::STANDARD};
use idevice::{Idevice, IdeviceError, provider::IdeviceProvider};
use serde_json::{Value, json};

use crate::{safe_error, tunnel::TunnelProvider};

pub const HTTP_PORT: u16 = 8100;
pub const MJPEG_PORT: u16 = 9100;

#[derive(Clone, Copy, Debug)]
pub enum Route {
    /// Through the Remote Pairing tunnel.
    Tunnel,
    /// Directly to 127.0.0.1 on the same iPhone (verified in 診断版6).
    Local,
}

pub fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

/// Minimal HTTP/1.1 request. Returns (status, body bytes).
async fn http(provider: &TunnelProvider, route: Route, method: &str, path: &str, body: &str) -> Result<(u16, Vec<u8>), IdeviceError> {
    let mut dev = match route {
        Route::Tunnel => provider.connect(HTTP_PORT).await?,
        Route::Local => {
            let s = tokio::net::TcpStream::connect(("127.0.0.1", HTTP_PORT)).await?;
            Idevice::new(Box::new(s), "local")
        }
    };
    let mut request = format!("{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n");
    if method == "POST" {
        request.push_str(&format!("Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}", body.len()));
    } else {
        request.push_str("\r\n");
    }
    dev.send_raw(request.as_bytes()).await?;
    let mut response: Vec<u8> = Vec::new();
    let mut header_end: Option<usize> = None;
    let mut content_length: Option<usize> = None;
    loop {
        let chunk = match dev.read_any(65536).await {
            Ok(c) => c,
            Err(_) if header_end.is_some() => break, // closed by WDA
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
    let code = String::from_utf8_lossy(&response[..h])
        .split_whitespace()
        .nth(1)
        .and_then(|c| c.parse().ok())
        .unwrap_or(0);
    Ok((code, response.split_off(h)))
}

/// WDA error name only (e.g. "unknown command"), never the whole body.
fn error_name(body: &[u8]) -> String {
    serde_json::from_slice::<Value>(body)
        .ok()
        .and_then(|v| v.pointer("/value/error").and_then(|e| e.as_str()).map(|s| s.chars().take(60).collect()))
        .unwrap_or_else(|| "-".into())
}

pub struct Wda {
    pub provider: TunnelProvider,
    pub session: String,
    /// Route used for normal commands. Switched to Local once it is verified.
    pub route: Route,
}

impl Wda {
    pub async fn call(&self, route: Route, label: &str, method: &str, path: &str, body: &str, secs: u64) -> Result<Vec<u8>, String> {
        match tokio::time::timeout(Duration::from_secs(secs), http(&self.provider, route, method, path, body)).await {
            Err(_) => Err(format!("{label}: タイムアウト（{secs}秒）")),
            Ok(Err(e)) => Err(safe_error(label, e)),
            Ok(Ok((200, body))) => Ok(body),
            Ok(Ok((code, body))) => Err(format!("{label}: HTTP {code} / {}", error_name(&body))),
        }
    }

    /// W3: wait for /status, W4: create a session.
    pub async fn start(provider: TunnelProvider) -> Result<Wda, String> {
        let mut wda = Wda { provider, session: String::new(), route: Route::Tunnel };
        crate::status("W3: WDAの起動待ち（最大60秒）");
        let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
        loop {
            match wda.call(Route::Tunnel, "W3", "GET", "/status", "", 8).await {
                Ok(_) => break,
                Err(e) if tokio::time::Instant::now() >= deadline => return Err(e),
                Err(_) => tokio::time::sleep(Duration::from_millis(500)).await,
            }
        }
        crate::status("W4: WDAセッション開始");
        let body = wda
            .call(Route::Tunnel, "W4", "POST", "/session", r#"{"capabilities":{"alwaysMatch":{}}}"#, 30)
            .await?;
        let v: Value = serde_json::from_slice(&body).map_err(|_| "W4: 応答の形式が不正".to_string())?;
        wda.session = v
            .get("sessionId")
            .or_else(|| v.pointer("/value/sessionId"))
            .and_then(|s| s.as_str())
            .ok_or("W4: セッションIDがありません")?
            .to_string();
        Ok(wda)
    }

    /// Prefer the on-device loopback when it answers (faster, tunnel independent).
    pub async fn prefer_local(&mut self) -> bool {
        let ok = self.call(Route::Local, "L1", "GET", "/status", "", 5).await.is_ok();
        if ok {
            self.route = Route::Local;
        }
        ok
    }

    pub async fn status(&self) -> Result<(), String> {
        self.call(self.route, "WDA応答", "GET", "/status", "", 8).await.map(|_| ())
    }

    pub async fn activate(&self, bundle: &str) -> Result<(), String> {
        let body = json!({ "bundleId": bundle }).to_string();
        self.call(self.route, "アプリを前面へ", "POST", &format!("/session/{}/wda/apps/activate", self.session), &body, 20)
            .await
            .map(|_| ())
    }

    pub async fn home(&self) -> Result<(), String> {
        self.call(self.route, "ホーム画面へ", "POST", "/wda/homescreen", "{}", 15).await.map(|_| ())
    }

    /// Tap in screen points via W3C actions (verified in 診断版5.1/6).
    pub async fn tap(&self, x: f64, y: f64) -> Result<(), String> {
        let body = json!({"actions": [{
            "type": "pointer", "id": "finger1", "parameters": {"pointerType": "touch"},
            "actions": [
                {"type": "pointerMove", "duration": 0, "x": x.round(), "y": y.round()},
                {"type": "pointerDown", "button": 0},
                {"type": "pause", "duration": 100},
                {"type": "pointerUp", "button": 0}
            ]
        }]})
        .to_string();
        self.call(self.route, "タップ", "POST", &format!("/session/{}/actions", self.session), &body, 15)
            .await
            .map(|_| ())
    }

    /// WDA/Appium settings, e.g. MJPEG scaling and frame rate.
    pub async fn settings(&self, settings: Value) -> Result<(), String> {
        let body = json!({ "settings": settings }).to_string();
        self.call(self.route, "設定変更", "POST", &format!("/session/{}/appium/settings", self.session), &body, 15)
            .await
            .map(|_| ())
    }

    /// Full-resolution PNG via /screenshot (slow; ~5.7MB base64 in 診断版6).
    pub async fn screenshot_png(&self) -> Result<Vec<u8>, String> {
        let body = self.call(self.route, "画面取得", "GET", "/screenshot", "", 30).await?;
        let v: Value = serde_json::from_slice(&body).map_err(|_| "画面取得: 応答の形式が不正".to_string())?;
        let b64 = v.get("value").and_then(|s| s.as_str()).ok_or("画面取得: 画像がありません")?;
        STANDARD.decode(b64).map_err(|_| "画面取得: 画像の復号に失敗".to_string())
    }
}
