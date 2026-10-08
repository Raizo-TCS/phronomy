# Migrating to r8 unit 7

Apply after core b337fc77dae530269bc34d895365032873d544ad (r8 unit 6).
Public Agent invocation, streaming, approval, cancellation and recovery signatures
and persistence record schemas are unchanged. The current unit 6 examples need
no source changes. Run them against the candidate using PHRONOMY_PATH and the
correct BUNDLE_GEMFILE for each example directory.

There are no compatibility aliases for removed internal APIs:

| Internal use | Replacement |
| --- | --- |
| AgentInvocationSessionBuilder | AgentInvocation plus the owning ExecutionEnvironment.build_agent_session |
| AgentInvocationSessionBuilder entry/prepared actions | InvocationActions |
| ExecutionSessionRunner.new(runtime: ...) | ExecutionSessionRunner.new(environment: ...) |
| OwnershipRegistry.for/existing_for(Runtime) | Pass an ExecutionEnvironment; EngineEnvironment adapts Runtime |
| ExecutionReceiver subclasses initialize(event_loop:) | initialize(channel:), preserving super |
| AgentInvocation.begin_llm_call! implicit Runtime lookup | Explicit llm_call_id from durable prepared execution |

ExecutionEnvironment is a private framework connection, not an application
configuration feature. Do not serialize environments, channels, sessions or live
registries. The default composition is installed by requiring phronomy. State
policy loading alone does not install a runtime. Existing persisted Agent/Tool
identities, revisions, authorization snapshots and recovery classifications are
retained. This change does not add support for exchanging in-flight unit 5 or
older execution snapshots with unit 6/7 workers.

Stop/drain old processes using the existing deployment procedure before replacing
code. Deploy all internal call-site changes together. The application package
contains a strict-base dry-run/applier, expected-tree verification, review patch,
validation logs and rollback guidance. Run --verify before and after commit.
