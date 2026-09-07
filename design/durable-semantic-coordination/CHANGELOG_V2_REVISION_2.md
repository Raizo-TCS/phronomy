# V2 revision 2 — 改訂内容

更新日: 2026-09-06 / 状態: Accepted

## 合意反映

| 項目 | 今回の修正 |
|---|---|
| RC-01 結果参照 | exact実行IDで状態・結果を読み取る契約と、ID受領前の停止に備えたownerからの候補発見を追加 |
| RC-02 保存成否不明 | 正常な不存在、read障害、CAS競合、commit成否不明を区別。同じ予約済みidentityで照合 |
| RC-03 wiring互換性 | 定義id/version・slot・graph・Persistence境界の最低照合と、確定済みfactの優先を明記 |
| RC-04 cancellation | 観測終了/shutdownとsemantic cancelを区別。子の状態別処理、競合、restart後の再発見を明記 |
| RC-05 保証表現 | 確定outcome再利用・同一identity復旧・外部成否不明は既存Recovery、に統一 |

ADR-029/030/031、実装設計、責務境界レビュー、READMEへ対応する規範的記述を反映した。
詳細契約と検証条件はRECOVERY_CONTRACT_CLARIFICATIONS.mdにまとめ、資料間で参照する。
承認前のProposed表記をAcceptedへ更新した。新機能の再承認を要求しない。

## 実装状態の訂正

引き継ぎ文書の旧実装件数・静的検証成功は、前セッションの報告として残す。
この分岐先で実装を再検証した事実にはしない。現在取得できたのは設計資料と引き継ぎ文書であり、
旧overlay/apply.py/APPLY.sh/VERIFY.shは未取得。再開手順も実ファイルの回収から始める形に更新した。

## 今回実施した確認

- 対象資料の承認状態、baseline、相互参照の整合確認。
- 旧い「未承認のため実装停止」表現と、外部効果のexactly-onceに読める保証表現の修正。
- RC-01〜05のADR・実装設計・検証条件への対応確認。
- ZIP構成、全文書のSHA256SUMS、ZIP/引き継ぎ文書の外部SHA256の検証。

対象repositoryのコード変更・RSpec実行は行っていない。
API名や例外名は未確認のものを作らず、baselineへの対応付けを実装前の必須作業とした。
