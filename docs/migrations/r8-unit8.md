# Migrating to r8 unit 8

Apply after core a601a0654ace42640f0251b129359ca1f326e3ad (unit 7).
This is a core-only change. The unit 6 examples at
ed455c52018338f7c5a4c2948ae0d7db131aa090 require no source changes.

Public Agent invocation/stream/approval/cancellation/recovery signatures and
Tool#call_async(args, cancellation_token:, config:) are unchanged. Tool::Operation
adds an explicit C06 operation entry and result transformation API; application
Tools do not need to adopt it. The supplied submitter applies to the default
offloaded operation only. Custom async implementations retain their existing
execution mechanism and configuration.

| Internal use | Replacement |
| --- | --- |
| Agent::ToolInvocationSessionBuilder.build / build_for_resume | The owning ExecutionEnvironment.build_tool_session, with resume_event/resume_phase when needed |
| ToolInvocationSessionBuilder transition constants | Agent::ToolInvocationTransitions |
| ToolInvocationSessionBuilder entry operations | Agent::ToolInvocationActions |
| ToolInvocation.start_authorization/runtime: and start_execution/runtime: | Pass environment: explicitly; never reconstruct it from a new global Runtime |
| Tool::ToolExecutor.call_async(runtime:) | Tool::Operation.call_async(submitter:) for contract consumers; default executor takes submitter: internally |
| Agent ToolBinding's custom-async detection and mapping mechanism | Tool::Operation.with_result_transform; Agent retains filter configuration |

Removed internal names have no aliases. Deploy all internal call sites together.
Do not persist execution environments, submitters, FSM sessions or parent sinks.
Durable IDs, record schemas, revision checks and saved approval evidence are
unchanged. The change does not certify new in-flight cross-version compatibility.
Use the existing stop/drain procedure before replacing running processes.

The application ZIP contains strict-base --check/--apply/--verify commands,
complete replacement files and deletions, expected-tree verification, a review
patch, validation evidence and rollback instructions. Run --verify before and
after commit. Verify examples with PHRONOMY_PATH pointing at the candidate and
unset a stale BUNDLE_GEMFILE before entering each Bundler context.
