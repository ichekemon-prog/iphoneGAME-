# WDA の再梱包（Tapilot 用）

`いま使うファイル/WebDriverAgent-v16.14.0-tapilot.ipa` は、Appium WebDriverAgent v16.14.0 の未署名 IPA を次のように組み替えたもの。

1. テストバンドル `PlugIns/WebDriverAgentRunner.xctest` を `Frameworks/WebDriverAgentRunner.framework` へ移動（中身はそのまま。Info.plist の CFBundleIdentifier は com.facebook.WebDriverAgentRunner.xctrunner.xctest）。PlugIns フォルダは削除。
2. ランナーの Info.plist に `TapilotTestBundle = Frameworks/WebDriverAgentRunner.framework` を追加。Tapilot はこの値を読み、XCTest の testBundleURL / XCTestBundlePath に使う（patches/idevice-run-over-rsd.patch の TEST_BUNDLE_SUBPATH）。キーが無い WDA は従来どおり PlugIns/<name>.xctest。

理由：
- SideStore 0.7.0 は PlugIns 内の全バンドルにプロファイルを要求するが、.appex にしか用意しない → .xctest で「A provisioning profile for the app could not be found」。
- SideStore（SideSign）は PlugIns 内の .xctest をメイン実行ファイル扱いで署名し、アプリの権限を付ける → dlopen が code signature invalid になる見込み。
- Frameworks 配下で名前に .framework を含めると、iloader（isideload）も SideStore も「権限なしの部品」として署名する。App ID も増えない。

未検証：XCTest が拡張子 .framework のテストバンドルを読み込めるか（2026-10-07 時点）。
