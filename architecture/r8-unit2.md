# r8 unit 2：親の予約確認とAgent受付

この単位はP02／P03の受付境界を実装する。基準はcore `16e6fcb2dd49836735598525114abfc256d0773e`。r8全体やPersistenceの全面整理の完了ではない。

## 責務と操作

| 担当 | 公開操作・共通規則 | 依存と内部実装 |
|---|---|---|
| 共通Persistence | `atomic`、`Transaction#participate`、`committed?`。同じPersistence、同期thread、有効scope、savepoint、commit応答を検証 | Storageの公開transaction・scope規則を利用。Agent／Team／Workflowや構成担当を選ばない |
| Agent | `Admission#accept_in`。入力記録・実行ID・Agentの受付とrevision更新を同一scopeへ保存 | Agentの保存担当を使用。親のkind・Team割当・subagent snapshot・Handoff予約を解釈しない |
| MultiAgent | `ReservedChildAdmission#admit`。親の取消・slot・子IDを検証し、Agent受付を同じscopeへ参加させる | 自分の保存担当が予約の根拠を読み、必要なguardを取得する |
| 保存担当 | `Agent::Persistence::Admission`、`MultiAgent::Persistence::Reservation` | raw Storage viewはこの境界で使用。ドメイン操作へraw viewを渡さない |

AgentのRuntime admission取得、FSM開始、live状態の反映は既存のExecutionCoordinatorが引き続き所有する。新しいAdmissionはその短い保存フェーズだけであり、Agent実行全体を親のDB transactionへ入れない。通常のアプリは新しい参加クラスを実装・生成する必要がない。

`phronomy_admission` は内部の現在の配線であり、Procやオブジェクトを保存しない。永続化するのは従来の相関情報と親子IDだけ。Team／subagent／Handoffの開始・再開担当が現在の参加者を渡す。保存済み実行への再接続はExactExecutionの同一ID照合と復旧規則を維持する。

## 保存順序と失敗

1. Agentが既存のRuntime受付を取得し、同期workerで保存操作を開始する。
2. MultiAgentが短い`atomic` scopeを開き、親のguardを取得してから予約を読み直す。
3. 親の取消・割当・子の識別子を検証する。Agentは同じscopeで入力内容・AgentExecution・AgentRootを保存する。
4. commit応答が成功した後に、Agent実行担当だけが受付結果を取得し、準備・FSM・live反映を進める。

参加操作の戻り値はcommit成功を意味しない。`accept_in`はnilを返し、Agent内部の`result`は外側のcommitまで利用できない。二重参加、別Persistence、別thread、終了後scopeは拒否する。同じbackendを包む別Persistenceも同一scopeと扱わない。raw backend transactionの中から新しくcommit所有者を名乗ることも拒否する。

明示的な入れ子はsavepointとして動く。内側が成功しても外側がrollbackした場合は未成立。参加処理中の例外を内側で捕捉しても、失敗したscopeの先行変更をcommitできない。LLM、Tool、scheduler、外部callback、非同期待機を参加処理へ入れない。

Storageのscope違反は`Persistence::TransactionError`へcause・backtraceを保持して変換する。この名前の変更は、保存成否が既知であるとの宣言ではない。IOError等の成否不明な保存失敗は変換・自動retryせず、既存のAgent復旧規則へ渡す。今回、一般化した保存成否照合APIは追加していない。

## 取消との競合

TeamはTeamRoot、subagentは親AgentRoot、Handoffはrouting recordをguardとする。PostgreSQLではそのguardの行ロックと既存の条件付き更新によって、取消・変更と子受付を順序付ける。子受付側の通常readだけでは、この保証は成立しなかった。

Handoff取消側は最初に子の状態を観測し、未完了／不在ならroutingをロックして**子の状態を再取得**する。待機中に子受付がcommitした場合、古い「不在」の判断を捨て、受付済みの子へ公開取消を送る。既に終端の実行への取消は従来どおり結果参照として扱う。

InMemoryは共有Monitor、SQLiteはtransactionと書込競合検出、PostgreSQLは行ロックを使用する。SQLiteで競合したtransactionは成功とみなさず、backendの失敗を扱う。分散leaseや外部副作用のexactly-onceは追加しない。実PostgreSQLでの待機順序はexamplesの新しい3件の並行テストで確認する対象であり、InMemory／SQLiteの成功から推定して済ませない。

## API・ファイル変更

- Agent::InitialPreparationの`build_admitted_execution`と3種の親検証・kind分岐を削除。Agent自身の受付共通処理とMultiAgentの予約判断へ分離した。
- 共通の参加frameworkを`persistence/transaction.rb`、Agent受付を`agent/admission.rb`、保存接続を既存の各domainの`persistence/`へ置いた。新しいディレクトリや独立Contractは増やしていない。
- Storage SPIに同期contextの`transaction_open?`を追加。Storage::Backendの継承実装には共通実装が提供される。継承しない独自SPI実装はこの操作も提供する必要がある。RBS・SPI snapshot・duck-typed backendの検証を更新した。
- Persistenceの既知scope失敗の公開型を`Persistence::TransactionError`へ統一し、旧Storage例外のaliasは設けない。Storageを直接使う処理では従来のStorage例外を使用する。
- RBSはsigに配置し、参加者factory、Agent受付、MultiAgentの依存を宣言する。動的な`phronomy_admission`注入も本書と利用箇所で追跡する。
- 依存解析のExecution境界規則を図のrevision表示名から分離した。unit名の更新で同期backendからExecutionへの禁止規則が解除されないことを回帰テストする。
- 保存recordの形式、ID、revision規則は変更していない。データ移行は不要。

## 残る課題

`Persistence#transaction`とdomain repositoryの一括窓口は現行利用箇所が残るため、この単位では全面削除していない。互換維持のために新しい旧名aliasを追加したものではないが、P01／DP04の完了条件は未達である。次にdomain照会・保存構成を移し、不要な窓口を利用側と同時に削除する。

MultiAgentの保存担当にはAgentのexecution／Handoff repositoryへの参照が残る。予約検証の所有者は整理したが、親子の公開投影・認可照会・結果取込まで隠蔽したとは扱わない。P04／F02／F03の残課題として、Agentが公開する操作と、MultiAgentが所有すべき保存形式を確定する。一般的なmetadata getterを足すだけの解決にはしない。

Agent／TeamのFSM接続、Workflowのdurableな子連携（P05）、複数記録の保存成否照合（P06）、残りの配置整理、155組・393件の意味的再判定も残る。今回のSVGは実装候補を描き、全体の循環解消を示す構想図にはしない。
