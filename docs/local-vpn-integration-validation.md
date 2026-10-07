# 本体内VPN統合：事前検証（2026-10-06）

## 現在地

- 診断版8は実機でAI判断によるゲーム進行まで確認済み（ユーザー報告）。
- 現在は無料Apple IDで本体とWDAを署名し、別アプリのLocalDevVPNを使用。
- 目的は、本体にローカルVPNを統合し、別アプリの導入を減らすこと。VPN構成へのユーザー許可の省略は目的に含めない。
- 本調査でソースの統合・ビルド・実機動作は実施していない。

## 最初の判定条件：署名権限

LocalDevVPNはNEPacketTunnelProviderを使うアプリ拡張で実装されている。
統合にはNetwork Extensionのpacket-tunnel-provider権限を含む適切な署名・プロビジョニングが必要。
Apple DTSは、無料のPersonal TeamはNetwork Extension providerのプロビジョニングをサポートしないと説明している。
したがって現在の無料署名のまま実機検証できるとは扱わない。有料Apple Developer Programの利用可否を先に確認する。
entitlementsファイルにキーを書くことや、unsigned IPAをビルドすることだけでは、この条件を満たさない。

有料アカウントで統合実証できても、一般利用者が無料Apple IDで再署名して同じ構成を使える証明にはならない。配布方式は別に検証する。

## 最小検証の順序

1. 有効な署名チームと、本体・拡張それぞれのNetwork Extension権限付きプロファイルを準備できるか確認。
2. 現行版と異なるBundle IDの検証用アプリを用意。本体UI＋Packet Tunnel拡張だけで、VPN追加・開始・停止・状態表示を確認。
3. 外部LocalDevVPNを切断して、内蔵VPNのみで端末のRemote Pairingサービスへの到達を確認。外部VPNは復旧用として残す。
4. Remote Pairing/TLS-PSK/RSD→WDA起動→直結画面取得→タップの順に確認。
5. 背景移行、Wi-Fi/携帯回線、VPN再接続、端末再起動後の再開を確認。

「VPNが接続中」だけでは成功としない。外部LocalDevVPN停止下でWDAの新規起動から操作まで成立することを統合成功条件とする。
IP設定は実機で成功したDevice IPだけでなくTunnel IPとマスクも確認して合わせる。

## ソースとライセンス

LocalDevVPNの現行LICENSEは独自のStosVPN License。単純なMITライセンスと扱わない。
再利用時は著作権・許諾表示、目立つ場所での出典、派生元の明記、同一・類似名称での再公開に関する条件を確認する。
今回の調査ではソースを製品へコピーしていない。
実装する場合は参照コミットを固定し、その時点のLICENSEと関連ファイルの条件を保存する。

## 一次資料

- https://github.com/jkcoxson/LocalDevVPN
- https://raw.githubusercontent.com/jkcoxson/LocalDevVPN/main/TunnelProv/PacketTunnelProvider.swift
- https://raw.githubusercontent.com/jkcoxson/LocalDevVPN/main/LICENSE
- https://developer.apple.com/documentation/xcode/configuring-network-extensions/
- https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment
- https://developer.apple.com/forums/thread/128767 （Apple DTSの無料Personal Team非対応の説明）

## 次に必要な情報

有料Apple Developer Programに登録済みか。未登録なら、購入を前提にせず、無料署名を維持する案と統合の価値を比較する。
