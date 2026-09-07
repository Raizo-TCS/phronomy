# V2復旧契約の明確化 — 承認済み追補

更新日: 2026-09-06 / 文書改訂: V2 revision 2

## 0. 位置づけ

本追補は、V2への追加提案5点に対するユーザーの承認を反映した規範的な実装契約である。
ADR-029/030/031およびImplementation Design V2と合わせて適用する。
元のV2責務境界を維持し、結果参照・保存成否不明・wiring互換性・キャンセル・保証表現を明確化する。
同じ論点の旧記述と差がある場合、本改訂の明確化を優先する。それ以外の既存ADRの契約を置き換えない。

対象baselineは `5472116cd99a63ec27875024c955ea82be612d6b` のままとする。
これは仕様の承認であり、実装完了やテスト成功を意味しない。
公開メソッド名・例外名・既存キャンセル実装への対応付けはbaseline確認後に確定する。
本書の要件IDは追跡用の文書上のIDであり、新しいRuntime ID・永続ID・APIではない。

## 1. RC-01 — 確定結果の参照と実行の発見

### 必須契約

- Applicationはsemantic execution IDを指定して、owner identity、実行状態、確定結果またはエラーを読み取り専用で取得できる。
- 対象はAgentExecutionとTeamExecution。Handoff/Orchestratorは既存のrouting anchor・parent execution・予約済みchild/Target IDを使用し、参照のための新しい実行entityを作らない。
- Handoffでは指定した実行に結び付いたTarget outcomeを識別する。後続ターンの「最新のactive Agentの結果」を過去の呼び出し結果として代用しない。
- admissionがcommitした後、Applicationが実行IDを受け取る前に停止する場合に備え、既知のagent_id/team_idから実行候補を発見できる公開経路を用意する。activeだけでなくterminalとなった実行も対象とする。
- 結果参照・候補列挙はProvider/Tool起動、Agent continuation、callback再配送、ownership取得を伴わない。復旧を起動する操作とは区別する。
- 結果が未確定、不存在、参照不能を区別する。Persistence障害やresult materialization失敗を「実行なし」「処理中」「成功で結果なし」に変換しない。
- 基本状態と確定結果は保存済みrecordから取得する。継続実行に必要なgraph/Procを結果参照だけのために要求しない。既存codec/schemaの互換性要件は維持する。

### 範囲の制限

候補の発見は、Applicationのリクエストとの自動一意対応やsubmissionのexactly-onceを保証しない。
複数候補がある場合、時刻が最新という理由だけで対象と断定せず、Applicationが保持する相関情報と照合する。
Application固有のrequest ID・outbox・dedupはApplication責務であり、参照要件だけを理由に汎用idempotency基盤を追加しない。

既存のretention/delete契約を維持する。削除済み結果の復元、無期限保存、新しい履歴管理サービスは要求しない。
一覧の範囲・順序・ページング等は既存API/SPIを確認して最小限の公開経路に対応付ける。
既存APIで満たせない箇所のみ追加し、内部repositoryをそのまま公開契約として露出させない。

## 2. RC-02 — 不存在・競合・保存成否不明の区別

### 共通判断規則

| 観測 | 許可する判断・動作 |
|---|---|
| 正常なauthoritative readで予約済みIDの不存在を確認 | 親の最新状態・予約・キャンセル条件を確認し、同じ予約済みIDでadmissionを試みる |
| exact IDのnonterminalを確認 | 同じ実行の既存Recovery契約へ進む |
| exact IDのterminalを確認 | 保存済みoutcomeを利用する。replacement executionを作らない |
| read timeout / I/O failure / record decode failure | 不存在とみなさず、状態を保持して既存のerror/retry契約へ進む |
| write応答消失などでcommit成否不明 | 同じoperation identity・予約済みIDを保持してreadbackする。確認前に別IDや別assignmentを作らない |
| 明確なrevision/admission競合 | 最新のauthoritative factsを再読し、予約・owner・入力との整合を検証する。競合を単純な成功とみなさない |

readbackが利用する整合性は、admission/CASを保護する既存Persistence契約を満たすこと。
cache/indexの不一致や読み取り障害を新規admissionの根拠にしない。
不存在確認とadmissionの間の競合は既存のatomic admission/CASで防ぐ。
外部semantic workはadmissionの成功が確定した後にのみ開始する。

適用対象: Source Handoff transfer、Target admission/stabilization、parent child reservation/outcome、
Team admission/enqueue/finalize/assignment/worker outcome/terminal。
Team-owned enqueue/finalizeは既存方針のstable tool_invocation_idによるfact照合を維持する。

成否不明を解決できない間は、確定していないローカル推測で次のsemantic処理へ進まない。
無期限に同期待機せず、既存のPersistence error/retry経路へ制御を返す。
Applicationにストレージ上の事実を創作させるmanual resolutionは追加しない。
既存Agent/Persistenceの成否不明処理を再利用し、coordination専用の第二transaction engineを作らない。

## 3. RC-03 — 復旧時wiringの最低互換性

### 照合対象

| 対象 | 継続前に必要な照合 |
|---|---|
| Agent/Team定義 | 保存されたdefinition id/versionと現在の定義。既存の明示的な互換・移行契約がなければ一致を要求 |
| Orchestrator child | 保存済みslotとstatic subagent登録から解決した定義、予約済みagent_id/execution_id、ownerとの一致 |
| Handoff | original main anchor、保存済みactive/Target ID、必要なgraph接続、同じPersistence instance/domain |
| Team worker/coordinator | Team lineage、保存済みworker slotと定義、予約済みAgent/実行ID、保存済みassignmentとの一致 |

必要な登録やTargetがない、定義が不一致、Persistence境界が異なる場合は、semantic workを開始せずfail closedとする。
エラーから対象identityと不足・不整合の種類が分かるようにする。既存のconfiguration/rehydration error契約を使う。
結果の読み取りだけに不要な実行wiringを要求しない（RC-01）。

### 確定済みfactの優先

- 確定済みHandoffContextを現在のHandoffPolicyで再投影しない。
- 確定済みchild input/configを現在のデフォルトで置き換えない。
- 確定済みassignmentを現在のschedulerで選び直さない。
- 確定済みchild/worker/final aggregate outcomeを再計算しない。
- 未確定のscheduler/aggregateは既存V2のreplay-safe契約に従って再実行できる。保存済み入力に対する意味の互換性をApplicationが保つ。

Phronomyが検査できるのは宣言されたidentity/versionと構造であり、Rubyコードの意味の同一性ではない。
同じversionのまま非互換な実装に変更しないことはApplication責務。
versionを上げるだけで旧実行の復旧が自動的に可能になるわけではなく、対応する定義または既存の明示的移行契約が必要。
Proc/Classの永続化、ソースハッシュ、policy descriptor、global generic class registryは追加しない。

## 4. RC-04 — 待機終了とsemantic cancellation

### 操作の区別

| 操作・状態 | 契約 |
|---|---|
| Applicationが待機をやめる・接続が切れる・観測timeout | それだけではdurable executionへのsemantic cancellationとしない |
| Runtime shutdown / process loss | それだけではsemantic cancellationを確定しない。既存shutdown/draining契約で実行を保存・復旧可能に保つ |
| 明示的なsemantic cancellation要求 | 既存Agent cancellation契約に従い、対象owner/runと予約済み実行に対応付ける |
| recovery resolution / approval待ち | failureや自動cancelへ変換せず、既存V2のrehydration経路を維持する |

既存Taskの明示cancelなど、もともとsemantic cancellationを要求するAPIはその契約を維持する。
単なる観測終了と同じ操作として扱わない。具体的な公開API対応はbaseline確認時に記載する。

### 子実行への適用

| 子の状態 | 親runへのsemantic cancellationが受理された場合 |
|---|---|
| 予約済み・未開始 | 現在の親runに属する新規dispatchを止める。予約情報を失わず、キャンセルのために子を起動しない |
| 実行中・admission競合中 | exact reserved IDの状態を確認し、既存Agent cancellationを適用する。単にローカルTaskを破棄して処理済みとみなさない |
| terminal | durable outcomeを維持する。過去の成功・失敗をキャンセル済みに書き換えたり補償再実行したりしない |

親cancelと子admissionの競合は、最新の親run状態・既存admission契約で処理する。
既にadmitされた子は実行中の規則で照合し、別IDの子を作らない。
親terminalizationと子settlementの順序は既存Agentのcancel/terminal barrier契約へ対応付ける。
未完了の子がある場合、そのexact IDと必要なcancel/reconciliation状態を失ってはならない。
restart後にも既存の復旧経路から対象を発見できることを必須とし、未対応の子を忘れたまま親の全処理完了を主張しない。
新規の公開terminal statusや別のcancel schedulerを本追補だけで追加しない。

キャンセルの範囲は当該親runが所有する子に限定し、共有Agentの別実行・後続Team runへ波及させない。
HandoffのSourceはtransfer commit後にhanded_offであり、後からSourceをcancelしてtransferを取り消したことにしない。
現在のHandoff turnに対する明示cancelは、保存済みrouting/予約から該当Target実行へ対応付ける。
観測終了・cancelを理由にactive responsibilityを元のmain Agentへ戻さない。

外部Provider/Toolのcancelは副作用の取り消しを保証しない。成否不明は既存Agent Recovery契約で解決する。
既存機構で上記の順序・再発見を満たせず第二実行エンジン等が必要なら、Stop Conditionとして報告する。

## 5. RC-05 — durability保証の統一表現

> 確定済みのdurable outcomeは再利用する。未完了の実行は同じsemantic identityで復旧する。
> 外部Provider/Tool処理の成否不明は既存Agent Recovery契約に従って解決する。

「開始していないと確認できた場合だけ開始」はframework-owned execution admissionの判断を指す。
外部システムへのリクエストが一度も届いていないことや、外部副作用のexactly-onceを意味しない。
未完了実行を同じIDで復旧することも、内部の全Provider/Tool呼び出しの無条件再送を意味しない。
callback喪失、ローカルTask喪失、観測timeoutをsemantic work再実行の理由にしない。

## 6. 検証条件・対応付け

以下は必要な振る舞いの検証条件であり、新しいspecファイルの本数指定ではない。
既存specが契約を検証している場合はその根拠を記録し、不足ケースのみ追加する。

| ID | 検証シナリオ | 必須結果 |
|---|---|---|
| RC-01-A | terminal commit後、callback前にprocess loss | exact IDで同じ結果を読み取れ、semantic work/callbackを再実行しない |
| RC-01-B | admission応答前にcallerを失い、実行はterminalになる | owner identityから候補を発見できる。複数候補を勝手に一つへ決めない |
| RC-01-C | graph/listenerなしで結果参照、または結果のread/decode失敗 | 不要なwiringを要求しない。参照失敗を成功・不存在に偽装しない |
| RC-02-A | 各semantic commitの成功直後に応答を喪失 | readbackで既存factを採用し、別ID・二重assignmentを作らない |
| RC-02-B | read障害、authoritative不存在、CAS競合を別々に注入 | 状態を混同せず、成功が確定したadmission後だけ実行する |
| RC-02-C | 成否不明後のreadbackも失敗 | 状態を保ち制御を返す。無期限の同期待機・新規実行をしない |
| RC-03-A | subagent登録削除、定義version不一致、Target不足 | 継続前にfail closed。別定義・別Targetに置き換えない |
| RC-03-B | 互換な現在のwiringで復旧 | 確定済みContext/input/assignment/outcomeを再計算しない |
| RC-04-A | 待機終了・shutdown・process loss | 暗黙のsemantic cancellationを確定しない |
| RC-04-B | 親cancel時に子が未開始／active／terminal | 状態別規則を守り、exact ID・確定outcomeを維持する |
| RC-04-C | 親cancelとchild admission/terminalを競合させる | 子を紛失せず、既存cancel/terminal barrierへ整合する |
| RC-04-D | cancel要求後の各commit境界でprocess loss | 同じrunの未完了子を復旧経路から発見・照合できる |
| RC-04-E | Handoff transfer後の観測終了・明示cancel | Sourceへ巻き戻さず、当該Target実行にだけ適用する |
| RC-05-A | 外部Tool効果の成否不明とcallback喪失を別々に注入 | 前者は既存Recovery、後者は確定結果参照。盲目的再実行なし |

baseline統合時には、各RC IDについて「公開API/SPI・実装箇所・既存/追加spec」を対応表に記録する。
特に結果発見API、互換version扱い、cancel/terminal barrierは未確認のメソッド名で完了扱いにしない。
focused・backend・fault・full suiteの実行成功は、target checkoutでの実測が必要。
本資料改訂時点では実行していない。

## 7. 増やさない責務

callback outbox/ACK、terminal-delivery index、standalone fan-out用synthetic execution、
Proc/Class serialization、global generic registry、独立Persistence間のdistributed transaction、
Team専用の第二execution engineは引き続き対象外。
公開結果参照はApplicationの通知配送・外部副作用dedupを代替しない。

## 8. 実装との対応

2026-09-07の実装・公開API/SPI・検証範囲は
[IMPLEMENTATION_REPORT.md](IMPLEMENTATION_REPORT.md)を参照する。
本追補の責務境界と必須契約は変更しない。
