# Durable Semantic Coordination V2 revision 2 — Implementation report

作成日: 2026-09-07。設計承認日: 2026-09-06。
対象baseline: `5472116cd99a63ec27875024c955ea82be612d6b`。
承認済みADR-029/030/031とRC-01〜05に対する新規実装です。
旧Complete Durability overlay、既存の作業ZIP、synthetic fan-out executionは使用しません。

## 実装範囲

| 対象 | 実装した動作 |
|---|---|
| Persistence | root/transaction viewともに8 repository。新しい3 recordはcurrent format `0.1`。Backendはopaque DurableRecordと明示的なidentity/revision/index metadataを扱う |
| Handoff | Agent-domain APIへ移設。Source terminal・Context・exact Target予約・責務移転を同じtransactionで保存。Target terminalとrouting安定化も同一transaction |
| Orchestrator | 既存parent AgentExecutionのstatic subagent Toolにchild ID/input/knowledge/config/outcomeを保存。直接の`dispatch_parallel`/`fan_out`にはsynthetic parentを作らない |
| Team | TeamRoot/TeamExecution、task、worker slot、exact assignment/outcomeをCASで保存。coordinator/workerは既存Agent engineを使用。スケジューリングは既存の逐次方式 |
| Team内部操作 | 保存済みのauthorized Tool batchをProvider順に適用。各`tool_invocation_id`の結果を保持し、`enqueue_task`/`finalize`を自動照合 |
| Aggregate | pure/replay-safeな計算。canonical JSON結果またはエラーをterminal commit。保存前のクラッシュでは再計算可能、保存済みterminalでは再計算しない |
| Runtime | Teamのprocess-local所有・admission・drainを追加。新しいTeam FSM/Workflow engineは追加しない |
| Recovery | framework-owned操作はexact factから再開。外部Toolと混在したbatchでは外部の事実だけを既存Recovery APIで解決する |
| 終了・削除 | exact子のcancel/reconciliation情報を保持。idle main Agentの`purge!`はHandoff anchorも同時削除。未完了turnのanchor削除は拒否 |

Handoff graphは同じPersistence **instance**を使います。元main Agent IDがrouting anchorです。
保存済みContextを新しいpolicyで再投影せず、保存済みworker割当を現在のschedulerで選び直しません。
RuntimeのClass/Proc、listener、Task、CancellationTokenは永続化しません。

## 公開経路

| 目的 | API / 返却値 |
|---|---|
| Agent結果参照 | `store.execution_result(execution_id)`。owner、status、phase、result/errorと参照IDの凍結Hash |
| Handoff結果参照 | `store.handoff_result(source_execution_id)`。そのturnのexact Targetまで辿る。graph/Agent hydration不要 |
| Agent実行発見 | `store.list_executions(agent_id, after: nil, limit: 100)`。immutable execution records。active/terminal双方 |
| Team結果参照 | `store.team_execution_result(run_id)` または `team.result(run_id)` |
| Team実行発見 | `store.list_team_executions(team_id, after: nil, limit: 100)` または `team.executions(...)` |
| Handoffの実行/復旧 | `Agent::HandoffRunner.new(main_agent:, handoffs:).invoke(input, config: {})`。未完了turnがあれば保存済み予約・入力を使用 |
| static childの復旧 | `Orchestrator#resume(execution_id, config: {})` |
| Teamの作成/復旧 | `team_definition id:, version:`、`create(team_id:, persistence:)`、`load(team_id, persistence:, on_event:)`、`resume(run_id)` |
| 明示cancel | `team.cancel(run_id)` / `handoff_runner.cancel(execution_id)`。Orchestratorを含むAgentの既存操作は`config[:cancellation_token]` |

一覧順はsemantic IDの辞書順、`after`は排他的ID cursor、`limit`は正の整数です。
時刻順やリクエスト一意対応を意味しません。Applicationは候補を自身の相関情報と照合します。

Agentの結果statusは既存Symbol、Teamの結果statusはcanonical Stringです。
Teamのdefault aggregate結果もcanonical JSONのためHash keyはString、errorは例外オブジェクトではなく
`class`/`message`等のデータです。aggregateに渡すassignmentのトップレベルとtask keyはSymbolです。

Handoffの未開始Target予約は`status: :active, phase: :target_pending, reserved: true`で識別します。
明示cancelした未開始Targetは予約IDを保持し、過去turnの結果に後続turnを代用しません。
不存在は`Persistence::NotFoundError`、読み取り/復号失敗はそのエラーを返します。
削除された結果を復元する機能や無期限retentionは追加していません。

`Team.load`はTeam factsのhydrationのみです。子の実行/復旧は`resume`で開始します。
Agentの`load`は既存Recovery契約を維持します。結果だけが必要なら上記Persistence参照APIを使います。
Teamの`on_event`はhidden Agentsへ渡し、必要なRecovery/approval eventを受け取ります。
`Team.stream`はcommit済みassignmentのRuntime通知です。新しい通知配送保証はありません。

## RC対応表

パスはリポジトリroot相対です。共通の追加障害specは
`spec/phronomy/multi_agent/durable_coordination_spec.rb`です。

| 要件 | 主な実装 | 検証根拠 |
|---|---|---|
| RC-01-A/B | `Persistence#execution_result` / `list_executions`、Team対応API | owner未loadの再構築環境でactive/terminal候補・ページング・結果を読み、Provider/所有登録を増やさない |
| RC-01-C | `Persistence#handoff_result`、読み取り専用materialization | graph/ownerなしの予約参照、read障害、purge済み結果のNotFound。callback政策は既存`stream_callback_error_policy_spec.rb`でも検証 |
| RC-02-A | Agent準備の既存F1 readback、`reconcile_terminal_error`、Team `admit`/`update` | Teamの各revision commit直後の応答喪失、Source移転の応答喪失、確定worker/child outcomeの再利用 |
| RC-02-B/C | exact予約照合・atomic admission/CAS・bounded readback | read失敗と不存在を区別。Team admission後のreadback失敗ではdispatchなし。Backend契約はstale CAS、active重複、8 repository rollbackを検証 |
| RC-03-A | Team definition snapshot、static child slot定義、Handoff graph/Target照合 | worker version不一致とTarget/graph不足でfail closed。既存Handoff統合specで別Persistenceを拒否 |
| RC-03-B | immutable Context/input/knowledge/assignment/outcome | 現在policyを変更しても保存済みHandoffContextを使用。worker結果・static child結果・knowledge metadataを保持 |
| RC-04-A | 既存Task待機/Runtime shutdown契約 | `task_spec.rb`、`agent/acs16_task_quiescence_spec.rb`、Runtime/admission specs。Runtime再構築テストで暗黙cancelを追加しない |
| RC-04-B/C/D | Team cancel flag、Handoff exact cancellation、Agent子admission条件、既存terminal barrier | 予約worker/Targetを起動せずID保持。外部fact待ちのactive childを持つparentはactiveのままcancel情報を保存し再起動後も保持。既存admission/physical-quiescence specsと合わせて確認 |
| RC-04-E | Source terminal linkとTarget cancel。責務はTargetのまま | transfer後cancel→再起動→後続turnでもSourceへ戻らず、過去の予約IDとcancel結果を維持 |
| RC-05 | callback/外部効果とsemantic recordの分離 | mixed external/framework Tool batchは外部factだけresolveし、完了childを再実行しない。内部`finalize`の事実をApplicationへ問い合わせない |

`lib/phronomy/testing/persistence_contract/coordination_repositories.rb`の新shared examplesは、
外部backendにも公開される`phronomy/testing/persistence_contract`経由で実行されます。
raw SPI/API snapshot/RBS、旧Handoff定数削除、EventLoop単一writer/causal barrier、
logical-operation tracingの既存guardも維持しています。

## 検証の範囲と限界

実測環境はRuby 3.3.6。使用gemは配布ZIPの`verification/gems.txt`に記録します。
配布対象に対する実測コマンド、結果、ログは同梱の検証記録を参照してください。

- 通常RSpecは外部LLMへの接続を要するintegration tagを除外します。
- 選択したHandoff/Orchestrator/Team integrationはWebMockで実行します。
- 追加F4テストは、commit済みDurableRecordを複製し、新Backendと新Runtimeで復旧するモデルです。
  これは実OSプロセスの強制終了や物理ディスクへのfsyncの実証ではありません。
- 実LLM、Redis、PostgreSQL、OpenTelemetry等を使う別スイートは今回の実測対象外です。
  optional依存/service未設定59件と既存obsolete2件の計61件がpendingです。
- 外部backendのF4保存性と複数processの排他は、そのbackendとdeploymentの契約に依存します。
  InMemory自身はプロセス終了後の保存を保証しません。
- semantic cancellationは外部効果のrollbackではありません。TokenオブジェクトはRuntime-onlyです。
  durable cancel flag/factがcommitした後は保持し、未確定外部処理は既存Recoveryで照合します。
  fact/approval待ちをfailedにして子を忘れず、`ExecutionRehydrationRequiredError`で制御を返します。

Frameworkが実施するのは、確定outcomeの再利用と未完了実行の同じsemantic identityでの復旧です。
callback outbox/ACK、global generic class registry、Proc/Class永続化、distributed transaction、
Team専用の第二execution engineは追加していません。

## パッケージ

完全版ファイルと削除manifestを同梱します。baseline/適用前後のハッシュを検査して適用します。
新しいClassの配置をZeitwerkの命名規則に合わせ、旧overlayのdecorator ignoreは不要です。
旧`MultiAgent::Handoff*`、`Runner`、`Coordinator`、`CoordinationState`の実装を削除します。
適用・依存関係・VERIFY手順は配布rootの`README_APPLY_JA.md`を参照してください。
