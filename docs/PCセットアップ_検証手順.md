# PCセットアップ（認証ファイル自動配置）検証手順（2026-10-07、Claude）

## Claudeが事前に確認したこと
- iloader `80142ff8…` の `src-tauri/src/pairing.rs` は原本ハッシュ一致。`setup/iloader-phone-runner.patch` は `git apply` 成功。
- パッチ適用後のiloaderを **Linuxで `cargo check` → エラーなし**（Windows用EXEのビルドは未実施）。
- iloaderの対象アプリ判定は `CFBundleDisplayName` の完全一致。本体は project.yml で「Phone Runner Probe」を設定済み → 一覧に出る見込み。
- iloaderの配置ファイルは lockdown情報＋Remote Pairing情報（`public_key`/`private_key`/`identifier`）の合成plist。iloaderと本体のidevice（どちらも0.1.68）は同じキー名で、余分なキーは読み飛ばす → 本体の `PairingSetup.valid` とRustの `RpPairingFile::from_bytes` の両方で読める。
- 「ペアリングファイルの管理」はApple IDのログイン不要（端末選択のみ）。署名・証明書の操作には触れない。
- 本体Rustの全テスト（coordinates／diagnostics／find_wda／capture）成功。

## GitHubに追加するもの
1. `setup/iloader-phone-runner.patch`（リポジトリにない場合）
2. `.github/workflows/build-pc-setup.yml`（中身は `setup/build-pc-setup.yml.txt`。GitHubの「Add file → Create new file」でパスを入力して貼り付け）

## ビルド
- Actions →「Build PC setup tool (Windows, verification only)」→ Run workflow。
- 成果物 `PhoneRunner-PCSetup-windows`：`iloader.exe`（そのまま起動可）とNSISインストーラ。
- 署名なしのためWindowsの警告（SmartScreen）が出る。検証用の個人ビルド。iloaderの名前・ロゴはMITの対象外（LICENSE-BRANDING）なので、配布する場合は名称・アイコンを変える。

## 現用iPhoneでの安全な検証（既存の認証は消さない）
1. エージェントを止めた状態で、iPhoneをUSB接続（ロック解除、「信頼」済み）。
2. `iloader.exe` を起動 → 端末を選択（初回はペアリング生成で少し待つ）。
3. 「ペアリングファイルの管理（Ctrl+P）」→ 一覧に **Phone Runner Probe** が出るか。
4. 「配置」→ 成功表示。
5. iPhoneでProbeを開く → 既存の認証があるため**自動では差し替えず**、その旨が表示されることを確認（既存設定の保護）。
6. 接続診断が今まで通り通ることを確認。
- 受け取り成功（新規端末で自動取込→受け渡しファイル削除→診断通過）は、認証未設定の端末で別途確認する。
