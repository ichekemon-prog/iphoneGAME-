//! Engine: restores the Developer Disk Image (DDI) on the device itself,
//! e.g. after a reboot. Game independent.
//! The image files are downloaded by the app (Swift) into `dir` beforehand.
use std::path::Path;

use idevice::{RsdService, mobile_image_mounter::ImageMounter, rsd::RsdHandshake};

use crate::{step, tunnel::Tunnel};

pub const FILES: [&str; 3] = ["Image.dmg", "Image.dmg.trustcache", "BuildManifest.plist"];

pub fn has_testmanager(h: &RsdHandshake) -> bool {
    h.services.keys().any(|name| name.contains("testmanagerd"))
}

pub fn files_ready(dir: &str) -> bool {
    !dir.is_empty()
        && FILES
            .iter()
            .all(|f| Path::new(dir).join(f).metadata().map(|m| m.len() > 0).unwrap_or(false))
}

fn read(dir: &str, name: &str) -> Result<Vec<u8>, String> {
    std::fs::read(Path::new(dir).join(name)).map_err(|e| format!("D0: {name} を読めません io={:?}", e.kind()))
}

/// Returns Ok(false) when nothing was needed, Ok(true) when the DDI was mounted now.
pub async fn ensure(t: &mut Tunnel, dir: &str) -> Result<bool, String> {
    if has_testmanager(&t.handshake) {
        return Ok(false);
    }
    if !files_ready(dir) {
        return Err("D0: 開発用ディスクイメージのファイルが未準備です".into());
    }
    let image = read(dir, FILES[0])?;
    let trust_cache = read(dir, FILES[1])?;
    let manifest = read(dir, FILES[2])?;
    let ecid = t
        .handshake
        .properties
        .get("UniqueChipID")
        .and_then(|v| v.as_unsigned_integer())
        .ok_or("D1: 端末の識別値（UniqueChipID）を取得できません")?;
    let mut mounter: ImageMounter =
        step("D2: ディスクイメージ管理サービスへ接続", 20, ImageMounter::connect_rsd(&mut t.handle, &mut t.handshake)).await?;
    step(
        "D3: 署名取得・転送・マウント",
        180,
        mounter.mount_personalized_rsd(&mut t.handle, &mut t.handshake, image, trust_cache, &manifest, None, ecid),
    )
    .await?;
    drop(mounter);
    step("D4: サービス一覧を再取得", 20, t.refresh()).await?;
    if has_testmanager(&t.handshake) {
        Ok(true)
    } else {
        Err("D4: マウント後もtestmanagerdが見つかりません".into())
    }
}
