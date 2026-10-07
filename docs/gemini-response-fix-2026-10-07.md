# Gemini 3.1のJSON応答エラー修正

## 根拠

ユーザーの15:13台のログでは、3回ともモデルの本文を受信した後にJSONDecoderが失敗し、操作を実行せず終了。2手目の表示に `"x":125,y:545` があり、少なくともこの応答はJSONキーの引用符が不正。
ログ末尾は従来コードが120文字に切り詰めていたため、画像だけから出力トークン上限による途中切れとは判断できない。
従来はデコード成功後だけトークンを集計していた。「トークン合計0」は実使用量ゼロを意味しない。

## 変更

- `App/AgentResponse.swift`へDecision/BrainErrorと応答処理を分離。
- generationConfigにresponseJsonSchemaを追加。action列挙、座標数値0〜1000、秒数、説明文の型を定義。
- finishReasonがSTOP以外なら操作しない。MAX_TOKENS等をログで区別。
- 同一候補内の本文partsを連結し、thoughtフラグ付き部分は除外。囲みコードフェンスのみ除去。
- 不正なJSONを文字列置換で修復して操作することはしない。tap/swipeの必須座標、waitの秒数をローカルでも確認。
- 形式不正でもusageMetadataのAPI報告トークン数を合計へ加える。取得できた分の集計であると表示。
- JSON不正ログはfinishReasonと本文文字数を表示。本文断片を途中切れと誤認する表示を廃止。
- 成功後も含めて実際の連続エラー3回で終了するよう修正。

公式仕様の参照：
- https://ai.google.dev/gemini-api/docs/structured-output
- https://ai.google.dev/api/generate-content#v1beta.GenerationConfig

## 検証

`tests/AgentResponseTests.swift`を追加しActionsで実行：正しいtap/swipe/wait/done、不正JSON、文字列座標、欠落・範囲外、未知action、MAX_TOKENS/SAFETY、本文分割、フェンス、使用量なし、失敗時使用量保持。
ローカルはSwiftコンパイラなし。テストとiPhoneビルドは未実行。Gemini APIを実際に呼んだ検証も未実施。
構造化出力を追加したことと、3.1で実機成功したことは区別する。

## 更新

変更は本体側のみ。WDAとPC版iloaderの作り直しは不要。
App/Agent.swift、App/AgentResponse.swift、tests/AgentResponseTests.swift、.github/workflows/build.ymlを同時反映する。
Actions成功後に本体IPAを従来のiloaderで更新。保存設定やBundle IDは変更しない。
最初は3.1 Flash Lite、最大1手、操作OFFで判断が読み取れるか確認。その後、少数手で実操作を確認する。
