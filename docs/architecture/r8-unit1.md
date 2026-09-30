# r8第1適用版：Context／ToolとExecutionの共通基盤

対象は2026-09-30に確認したmain `653e255a34fe4062d4beca47530e084fdd3a6ba9`。設計基準は同日更新のr8修正仕様・directory配置資料である。本変更はその第1適用単位であり、r8全体、S1全項目、S2/S3全受入条件の完了を意味しない。互換alias・転送だけの旧APIは残さない。

## 実装した責務と操作

| 所有者 | 共通基盤が実行すること | 利用側に残すこと |
|---|---|---|
| `Context::Assembly` | Policyを一度呼びPlanを検証する。内容を正規化し、最終予算を検査してManifestを保存する | Agentはsnapshotを取得し、保存直前のwatermark再確認とAgent実行記録更新を行う |
| `Tool::DefinitionSet` | Tool定義の正規化、名前重複と保存済み定義の整合性を検証する | Agentは自身のTool alias・decorator・runtime実体を準備する |
| `Tool::Authorization` | 不変の引数・認可contextでfacts→requirement→policy→decisionを評価する | Agentは対象実行の照合、承認状態、受付結果、supervisionを管理する |
| `Tool::ToolExecutor` | cooperative/offloadedの実行規則と結果を扱う | Engineのpool選択はExecutionの機構接続へ委ねる |
| `LLMAdapter::Base` / `RubyLLM` | 同期生成とchat構築・設定・message/tool-call構築。RubyLLM実装がSDK失敗を変換する | Agentは自身の保存データ・Tool定義を検証してadapterへ渡す |
| `Execution` | submitの入口、fan-out/fan-in、結果合成、取消・期限・待機規則 | Engineはpool・timer・RuntimeとFSMの機構を実装する |
| `Tracing::Observation` | 明示的な観測とPII秘匿。実際の返り値は変えない | Runnableはinvoke/stream/batchの実行契約を持つ |

ContextとToolはAgentの薄い型定義の置場ではなく、実際の共通手順を所有する。ただし、Contextの現在の入力にはAgent由来の識別情報や由来情報が残る。完全に汎用の新domainモデルまで設計し直したものではない。ToolのDSL基底は引き続きRubyLLM::Toolを使用する。

`Context::Assembly#prepare(input:, policy:, adapter_identity:)` は保存transaction外でPolicyを呼ぶ。`#store(prepared, contents:)` は呼出側が渡す同じtransactionのcontents repositoryだけを使い、自分では独立transactionを開始しない。初回とfollow-upのAgent commitは既存transaction内でManifestとAgentExecutionの参照を保存する。後続書込に失敗したときManifestもrollbackされ、Policyは再実行されない。live projectionをcommit後に適用する既存順序を維持する。これはP02のAgent／Context部分の検証であり、任意domainの外側transaction参加を完成させたものではない。

Executionは`_ExecutionBackend`の操作に依存する。構成処理が遅延providerを設定し、Engineの`ExecutionBinding`がsubmit/afterを実装する。settled TaskResultの生成・map/flat_map/all_settled・待機制約の確認ではEngineを読み込まない。Runtime取得は実際のsubmit/タイマー登録時に行う。単なる名義移管に留めず、機構参照をここへ集約した。

WorkflowのFINISHと終了値は`Workflow::Completion`が所有し、WorkflowRunnerがFSM側へ変換する。FSMSession専用のEvent／FSMProtocol／TerminalDecisionはEngineに置く。Agent・MultiAgentのFSM専用接続の全面分離は残っている。

## 公開名・配置の変更

| 旧配置・API | 新配置・API | 判断 |
|---|---|---|
| `agent/context_contract/` と `Agent::ContextPolicy` 等 | `context/`、`Context::ContextPolicy` 等 | Policy・Plan・Manifest・検証を共通操作と同じ所有者へ統合 |
| `agent/context_policies/default.rb` | `context/default_policy.rb`、`Context::DefaultPolicy` | 具体Policyも同domainに配置 |
| `Agent::Context::Instruction::PromptTemplate` | `Context::PromptTemplate` | Agent内の旧公開名を削除 |
| `Agent::Selection::{Candidate,Constraint}` | `Context::{Candidate,Constraint}` | 薄いSelection下位区分を削除 |
| `Agent::LLMInputPatch` / `LLMInputBuildContext` | `Context::LLMInputPatch` / `LLMInputBuildContext` | hook入力・返却値の所有を統一 |
| `ContextBudgetExceededError` | `Context::BudgetExceededError` | LLMのprovider失敗ではなくContext予算失敗 |
| `agent/context_assembly/` | `context/assembly.rb` とAgent直下の準備・状態・入力処理 | Context共通手順、Agent snapshot/state、LLM SDK処理を分離 |
| `Agent::Context::Capability::Base` | 実装本体の `Tool::Base` | 旧名とaliasを削除 |
| `agent/tool_execution/tool_definition_set.rb` | `tool/definition_set.rb` | 共通定義処理を移管。Agent固有生成はAgent内 |
| `execution_contract/` と `execution_services/` | `execution/` と必要な `execution/concurrency/` | 操作・値・共通規則を統合。`execution_result`等の薄い別分割を追加しない |
| `WorkerSubmission` | `Execution.submit` | 転送専用moduleを削除 |
| `Runnable#trace` | `Tracing::Observation.trace` | 実行基盤から観測への依存を除去 |
| `tool/contract`、`filter/contract`、`output_parser/contract`、`agent/lifecycle_contract` | 各所有domain配下の例外ファイル | 例外だけのdirectoryを削除。既存の意味を持つ例外定数名は実体として保持 |

独自LLM adapterはcomplete/streamだけでなく、`build_chat`、`configure_chat`、`message`、`tool_call`を実装する。`identity`には基底の既定値、`input_budget`にはnilの既定値がある。正確なkeywordと返却契約は`sig/phronomy/llm_adapter/base.rbs`を参照する。SDK固有例外はadapter操作の境界でLLM失敗へ変換し、元のcauseを保持する。アプリ例外・取消は無関係なprovider失敗へ変換しない。

既存設定APIの`tool_result_max_size`／loggerはアプリ構成から中立RuntimeSettingsへ供給する。Toolから構成factoryへの参照を除き、default・nil・scoped copyの意味を維持する。RBSは`sig/`と`sig/_private/`に置き、実装定数・宣言所有者に基づいて依存を解析する。

## r8項目別の到達点

| 項目 | この適用版 | 未完了部分 |
|---|---|---|
| DP01 Context集約 | 主対象を実装 | より広いdomain入力・公開操作レビューは残る |
| DP02 Tool共通基盤 | 定義・認可評価・呼出しの共通部分を実装 | Agent側FSM接続と全親子認可の整理はDP12/P04 |
| DP03 Execution統合 | 実装 | domain全体のFSM利用整理を完了としない |
| DP04 Persistence | 未着手 | facade除去、共通transaction/参加/成否照合API |
| DP05 domain保存schema | 未着手 | MultiAgent/Workflowのstorage_contract統合 |
| DP06 LLM集約 | 前提部分のみ | llm_contractとllm_adapterの全面統合 |
| DP07 薄い失敗directory統合 | 実装 | domainごとの失敗語彙全体の再設計ではない |
| DP08 composition集約 | 接続追加のみ | runtime/persistence/agent構成の物理統合 |
| DP09 Embeddings独立 | 未着手 | vector_storeからの独立配置 |
| DP10 Documents | 未着手 | loader/splitter再配置 |
| DP11 assembly/concerns分解 | 主対象を実装 | Agent固有処理はAgent直下に保持 |
| DP12 domain実行接続 | Workflow終了境界など一部 | Agent/ToolInvocation/Teamのdomain判断とFSM接続の全面分離 |
| DP13 Recovery/Handoff | 未着手 | domain復旧・Persistence成否照合・親子操作の所有整理 |
| P02保存参加 | Agent/Contextの既存transactionで検証 | 外側scope、savepoint、複数domainの公開参加API |
| P01/P03〜P06保存・親子連携 | 未着手 | 下記の原子性条件を確定する必要がある |
| 155組・393件の三角形レビュー | 再判定未完了 | 図の再解析は判定完了の代わりにはならない |

NC/F/RMの全項目を「対応済み」とする資料は作成していない。受入可否はこの表の実装単位と同梱テスト証拠に限定する。

## Persistenceをこの適用単位から外した理由

現在のAgent初回受付は保存transaction内でTeam予約を読む。AgentからTeam内部への参照は最終設計では解消すべきだが、検証を単純に先行呼出へ移すと次の競合が生じる。

1. 親側が予約の有効性を確認する。
2. 別の処理が予約を取り消す。
3. Agentが新しいtransactionで受付記録を保存し、取消済みの子を開始してしまう。

次の適用単位では、親が所有する予約確認とAgent受付記録を同一scopeで行う参加APIが必要である。親は予約規則、Agentは受付規則、Persistenceは参加とcommit境界を所有する。Agentが親kindをswitchしてTeamを選ぶ現在の逆依存を、新しいcallbackの裏へ隠すだけでは解決にならない。

具体的に未確定なのは、参加操作の公開keyword/返却値、取消との競合条件、commit後のRuntime admission、停止後の同じ子IDによる照会・再開である。Workflowのhalt/finish snapshotだけで任意action内の子実行が耐障害化されるとは扱わない。Workflow→Agent/Teamの具体経路、checkpoint、結果取込一回性をP05で定める。成否不明は単一record一致だけで成功にせず、複数domainの証拠をP06で定める。

そのため既存Persistence facade、Team受付検証、予約・子記録のtransaction境界を本変更では改変しない。保証を弱めた仮実装を入れず、次の仕様・実装単位として残す。

## 解析図の読み方

実ソースとRBSから再生成する。従来の水平帯・グループ色・個別module枠を維持し、文字の背景は透過。M33/M41/M44への矢印は表示のみ省略し、JSON・行列・境界判定にはすべて残す。旧IDは再利用せず退役させる。

これは修正版candidateの実測図であり、全r8完了時の構想図ではない。残る循環・逆依存もそのまま出力する。静的解析で見えない注入先・動的dispatchはRBSだけで完全に証明できない。Engine機構接続とdomain保存の実行テストを併用する。

```bash
bundle exec rbs -I sig validate
python -m pip install -r tools/architecture/tools/requirements.txt
python -m unittest discover -s tools/architecture/tests -v
# lib/sigをcommitした後、未公開candidateでは次の指定を用いる
python tools/architecture/refresh_diagram.py . tmp/architecture-r8-unit1 --candidate
```

同梱SVGのSHAは作成用のローカルcandidateを示す。利用者が適用してcommitしたSHAとは異なるため、適用後の図はそのcheckoutで再生成する。Rubyの検証環境、件数、skip理由、未検証環境と適用手順は配布パッケージの検証報告を参照する。
