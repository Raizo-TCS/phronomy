import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from check_abstractions import violations
from find_dependency_triangles import analyze, write_report


class AbstractionTests(unittest.TestCase):
    def test_tool_tracing_and_context_do_not_read_application_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            for domain in ['tool', 'tracing', 'context']:
                path = repo / 'lib/phronomy' / domain / 'consumer.rb'
                path.parent.mkdir(parents=True)
                path.write_text('''# Phronomy.configuration is only a comment
Phronomy.configuration.tracer
Phronomy.send(:configuration)
::Phronomy.public_send('configuration')
Phronomy::Configuration.new
''')
            found = violations(repo)
            self.assertEqual(12, len(found))
            self.assertEqual({'domain-reads-application-configuration'}, {v['kind'] for v in found})
            for path in repo.glob('lib/**/*.rb'):
                path.write_text('Phronomy::Tracing::Settings.current.tracer\nPhronomy::Tool::Settings.current.max_result_size\nPhronomy::RuntimeSettings.current.logger\n')
            self.assertEqual([], violations(repo))

    def test_neutral_settings_cannot_reacquire_tool_or_tracing_values(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            owner = repo / 'lib/phronomy/configuration/runtime_settings.rb'
            owner.parent.mkdir(parents=True)
            owner.write_text('attr_accessor :tracer, :trace_pii, :tool_result_max_size\n@tracer = nil\n')
            found = violations(repo)
            self.assertEqual(4, len(found))
            self.assertEqual({'runtime-settings-own-domain-values'}, {v['kind'] for v in found})
            owner.write_text('# tracer and trace_pii belong to Tracing\nattr_accessor :logger, :offload_pool_size\n')
            self.assertEqual([], violations(repo))

    def test_domain_values_cannot_be_read_through_runtime_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            consumer = repo / 'lib/phronomy/tool/base.rb'
            consumer.parent.mkdir(parents=True)
            consumer.write_text('''# RuntimeSettings.current.tracer is only a comment
Phronomy::RuntimeSettings.current.tool_result_max_size
RuntimeSettings.current.trace_pii
::Phronomy::RuntimeSettings.current.send(:tracer)
''')
            found = violations(repo)
            self.assertEqual([2, 3, 4], [v['line'] for v in found])
            self.assertEqual({'domain-value-read-through-runtime-settings'}, {v['kind'] for v in found})
            consumer.write_text('Settings.current.max_result_size\nPhronomy::RuntimeSettings.current.logger\n')
            self.assertEqual([], violations(repo))

    def test_domain_settings_do_not_reach_application_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            for directory_name in ['agent', 'workflow/execution', 'multi_agent']:
                path = repo / 'lib/phronomy' / directory_name / 'consumer.rb'
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("# Phronomy.configuration is only a comment\nPhronomy.configuration.logger\n::Phronomy.send(:configuration)\nPhronomy.public_send('configuration')\nPhronomy::Configuration.new\n")
            found = violations(repo)
            self.assertEqual(12, len(found))
            self.assertEqual({'domain-reads-application-configuration'}, {v['kind'] for v in found})
            for path in repo.glob('lib/**/*.rb'):
                path.write_text('Phronomy::RuntimeSettings.current.logger\nPhronomy::Agent::Settings.current.llm_adapter\n')
            composition = repo / 'lib/phronomy/runtime_composition/global_configuration.rb'
            composition.parent.mkdir()
            composition.write_text('Phronomy.configuration.__agent_settings\n')
            self.assertEqual([], violations(repo))

    def test_authorization_pool_sizes_belong_to_execution_connection(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / 'lib/phronomy/agent/tool_execution/tool_invocation.rb'
            path.parent.mkdir(parents=True)
            path.write_text('Phronomy::RuntimeSettings.current.authorization_pool_size\nsettings.authorization_queue_size\n')
            self.assertEqual({'domain-selects-execution-pool-resources'}, {v['kind'] for v in violations(repo)})
            path.write_text('environment.submit_authorization(timeout: limit, cancellation_token: token) {}\n')
            binding = repo / 'lib/phronomy/agent/runtime_binding/engine_environment.rb'
            binding.parent.mkdir()
            binding.write_text('Phronomy::RuntimeSettings.current.authorization_pool_size\n')
            self.assertEqual([], violations(repo))

    def test_cancellation_registration_disposal_is_execution_owned(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            source = '''# token.unregister_cancel_callback is a comment
token.unregister_cancel_callback(callback)
token.send(:unregister_cancel_callback, callback)
token.__send__('unregister_cancel_callback', callback)
token.public_send(:unregister_cancel_callback, callback)
'''
            for file in ['multi_agent/team_coordinator.rb', 'engine/concurrency/offload_pool.rb']:
                path = repo / 'lib/phronomy' / file
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source)
            owner = repo / 'lib/phronomy/execution/concurrency/result_subscriptions.rb'
            owner.parent.mkdir(parents=True)
            owner.write_text(source)
            found = violations(repo)
            self.assertEqual([2, 3, 4, 5, 2, 3, 4, 5], [v['line'] for v in found])
            self.assertEqual({'private-cancellation-registration-leak'}, {v['kind'] for v in found})
            for file in ['multi_agent/team_coordinator.rb', 'engine/concurrency/offload_pool.rb']:
                (repo / 'lib/phronomy' / file).write_text('subscriptions.explicit_cancellation(token) {}\nsubscriptions.close\n')
            self.assertEqual([], violations(repo))

    def test_generation_uses_public_agent_operations(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / 'lib/phronomy/generation/generator_verifier/workflow_builder.rb'
            path.parent.mkdir(parents=True)
            path.write_text('''# __invoke_async_with_event_sink is a comment
agent.__invoke_async_with_event_sink(input)
agent.send(:__invoke_async_with_event_sink, input)
agent.__send__('__invoke_async_with_event_sink', input)
''')
            found = violations(repo)
            self.assertEqual([2, 3, 4], [v['line'] for v in found])
            self.assertEqual({'generation-invokes-private-agent-operation'}, {v['kind'] for v in found})
            path.write_text('agent.invoke_async(input).on_complete {}\nagent_class.new(on_event: listener)\n')
            self.assertEqual([], violations(repo))

    def test_generation_default_parser_is_selected_by_composition(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / 'lib/phronomy/generation/generator_verifier.rb'
            path.parent.mkdir(parents=True)
            path.write_text('Phronomy::OutputParser::JsonParser.new\nPhronomy::OutputParser::StructuredParser.new\n')
            self.assertEqual({'generation-selects-concrete-parser'}, {v['kind'] for v in violations(repo)})
            path.write_text('DefaultParser.build\nparser.parse(text)\n')
            composition = repo / 'lib/phronomy/runtime_composition/generation_defaults.rb'
            composition.parent.mkdir()
            composition.write_text('Phronomy::OutputParser::JsonParser.new\n')
            concrete = repo / 'lib/phronomy/output_parser/structured_parser.rb'
            concrete.parent.mkdir()
            concrete.write_text('Phronomy::OutputParser::JsonParser.new\n')
            self.assertEqual([], violations(repo))

    def test_recovery_rules_are_agent_owned_and_persistence_evidence_is_domain_neutral(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / 'lib/phronomy/persistence/snapshot_comparison.rb'
            path.parent.mkdir(parents=True)
            path.write_text('# Agent is a comment\nPhronomy::Agent::RecoveryRules.normalize_subject(x)\n')
            self.assertIn('persistence-evidence-knows-domain', {v['kind'] for v in violations(repo)})
            path.write_text('record.revision == expected_revision\n')
            workflow = repo / 'lib/phronomy/workflow/execution/workflow_runner.rb'
            workflow.parent.mkdir(parents=True)
            for source in ['Phronomy::Recovery.compare_revisioned_snapshot()',
                           'Phronomy::Agent::RecoveryRules.normalize_subject(x)']:
                workflow.write_text(source + '\n')
                self.assertIn('recovery-rules-owner-leak', {v['kind'] for v in violations(repo)})
            workflow.write_text('Phronomy::Persistence::SnapshotComparison.compare_revisioned_snapshot()\n')
            agent = repo / 'lib/phronomy/agent/recovery/recovery_rules.rb'
            agent.parent.mkdir(parents=True)
            agent.write_text('module Phronomy::Agent::RecoveryRules; end\n')
            self.assertEqual([], violations(repo))

    def test_workflow_rules_do_not_select_engine_or_construct_events(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / 'lib/phronomy/workflow/execution/workflow_runner.rb'
            path.parent.mkdir(parents=True)
            path.write_text("# Runtime in a comment is harmless\nPhronomy::Runtime.instance\nPhronomy::Event.new\nWorkflowPhaseMachineBuilder.new\nrequire 'state_machines'\n")
            found = violations(repo)
            self.assertEqual([2, 3, 4, 5], [v['line'] for v in found])
            self.assertEqual({'workflow-selects-engine'}, {v['kind'] for v in found})
            path.write_text('WorkflowExecutionEnvironment.current\nTaskResult.deferred\nRuntimeShutdownError.new\n')
            binding = repo / 'lib/phronomy/workflow/runtime_binding/connection.rb'
            binding.parent.mkdir()
            binding.write_text('Phronomy::Runtime.instance\nPhronomy::FSMSession.new\n')
            self.assertEqual([], violations(repo))

    def test_coordination_cannot_select_runtime_or_register_shutdown_participants(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / 'lib/phronomy/multi_agent/admission_registry.rb'
            path.parent.mkdir(parents=True)
            path.write_text('''# Runtime is a comment
Phronomy::Runtime.instance
EngineEnvironment.new
runtime.__register_shutdown_participant(key: self, participant: new)
runtime.send(:__shutdown_participant, key: self)
''')
            found = violations(repo)
            self.assertEqual([2, 3, 4, 5], [v['line'] for v in found])
            self.assertEqual({'coordination-selects-engine'}, {v['kind'] for v in found})
            path.write_text('ExecutionEnvironment.current.admissions\nenvironment.submit {}\n')
            binding = path.parent / 'runtime_binding/engine_environment.rb'
            binding.parent.mkdir()
            binding.write_text('Phronomy::Runtime.instance\nruntime.__register_shutdown_participant(key: self, participant: new)\n')
            self.assertEqual([], violations(repo))

    def test_coordination_uses_tool_contract_without_concrete_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / 'lib/phronomy/multi_agent/orchestrator.rb'
            path.parent.mkdir(parents=True)
            path.write_text('# Phronomy::Tools::Agent is a comment\nClass.new(Phronomy::Tools::Agent)\n')
            found = violations(repo)
            self.assertEqual([2], [v['line'] for v in found])
            self.assertEqual({'coordination-selects-concrete-tool'}, {v['kind'] for v in found})
            path.write_text('Class.new(Phronomy::Tool::Base)\nPhronomy::Agent::Base\nPhronomy::ExecutionRehydrationRequiredError\n')
            self.assertEqual([], violations(repo))

    def test_tool_contract_does_not_interpret_agent_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / 'lib/phronomy/tool/base.rb'
            path.parent.mkdir(parents=True)
            path.write_text('Phronomy::ExecutionRehydrationRequiredError\n')
            self.assertEqual({'llm-tool-contract-owner-leak'}, {v['kind'] for v in violations(repo)})

    def test_agent_domain_cannot_select_concrete_policy_or_async_client(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / 'lib/phronomy/agent/base.rb'
            path.parent.mkdir(parents=True)
            path.write_text('# DefaultPolicy is a comment\nPhronomy::Context::DefaultPolicy.instance\nPhronomy::LLMAdapter::AsyncClient.new\n')
            found = violations(repo)
            self.assertEqual([2, 3], [v['line'] for v in found])
            self.assertEqual({'agent-selects-concrete-policy-or-client'}, {v['kind'] for v in found})
            path.write_text('Phronomy::Context::ContextPolicy\nenvironment.build_llm_client(adapter: adapter)\n')
            binding = path.parent / 'runtime_binding/engine_environment.rb'
            binding.parent.mkdir()
            binding.write_text('Phronomy::LLMAdapter::AsyncClient.new\n')
            composition = repo / 'lib/phronomy/runtime_composition/agent_defaults.rb'
            composition.parent.mkdir()
            composition.write_text('Phronomy::Agent::Base.context_policy(Phronomy::Context::DefaultPolicy.instance)\n')
            self.assertEqual([], violations(repo))

    def test_agent_progress_cannot_select_engine_implementation(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / 'lib/phronomy/agent/execution/policy.rb'
            path.parent.mkdir(parents=True)
            path.write_text("# Runtime is an implementation detail\nPhronomy::Runtime.instance\nrequire 'state_machines'\nEngineSessionBuilder.build\n")
            found = violations(repo)
            self.assertEqual([2, 3, 4], [v['line'] for v in found])
            self.assertEqual({'agent-progress-knows-engine'}, {v['kind'] for v in found})
            path.unlink()
            binding = repo / 'lib/phronomy/agent/runtime_binding/connection.rb'
            binding.parent.mkdir()
            binding.write_text("Phronomy::Runtime.instance\nPhronomy::FSMSession.new\n")
            self.assertEqual([], violations(repo))

    def test_tool_child_progress_cannot_select_fsm_or_tool_implementation(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / 'lib/phronomy/agent/tool_execution/policy.rb'
            path.parent.mkdir(parents=True)
            path.write_text("Phronomy::Runtime.instance\nPhronomy::FSMSession.new\nToolSessionBuilder.build\nPhronomy::Tool::ToolExecutor.call_async\nrequire 'state_machines'\n")
            found = violations(repo)
            self.assertEqual([1, 2, 3, 4, 5], [v['line'] for v in found])
            self.assertEqual({'agent-progress-knows-engine', 'agent-selects-tool-implementation'}, {v['kind'] for v in found})
            path.write_text("environment.submit {}\nPhronomy::Tool::Operation.call_async\n")
            self.assertEqual([], violations(repo))

    def test_llm_tool_contracts_reject_sdk_and_orchestration_references(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            for file, source in [
                ('tool/base.rb', 'class Base < RubyLLM::Tool; end\nPhronomy::Agent::Base\n'),
                ('llm_adapter/base.rb', 'Phronomy::Runtime.instance\nPhronomy::Tool::Base.new\n'),
                ('agent/base.rb', 'RubyLLM::Message.new\n'),
            ]:
                path = repo / 'lib/phronomy' / file
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source)
            found = violations(repo)
            self.assertEqual(5, len(found))
            self.assertEqual({'llm-tool-contract-owner-leak'}, {v['kind'] for v in found})

    def test_agent_admission_does_not_interpret_parent_records(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / 'lib/phronomy/agent/admission.rb'
            path.parent.mkdir(parents=True)
            path.write_text('scope.participate {}\n# tx.team_executions\ntx.team_executions\nx.send(:assignments)\n')
            self.assertEqual([3, 4], [v['line'] for v in violations(repo)])

    def test_transaction_framework_does_not_select_a_domain_or_its_composition(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / 'lib/phronomy/persistence/transaction.rb'
            path.parent.mkdir(parents=True)
            path.write_text('# Agent is only a comment\nPhronomy::Agent::Base\nPersistenceComposition::Repositories\n')
            found = violations(repo)
            self.assertEqual([2, 3], [v['line'] for v in found])
            self.assertEqual({'transaction-knows-domain-or-composition'}, {v['kind'] for v in found})

    def test_domain_operations_cannot_select_concrete_record_adapters(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / 'lib/phronomy/agent/admission.rb'
            path.parent.mkdir(parents=True)
            path.write_text('store.participate(scope) {}\nAgent::Persistence::Records.new(view)\n')
            self.assertEqual({'domain-selects-storage-implementation'}, {v['kind'] for v in violations(repo)})

    def test_team_uses_public_agent_operations_instead_of_records_or_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / 'lib/phronomy/multi_agent/team_coordinator.rb'
            path.parent.mkdir(parents=True)
            path.write_text('''persistence.agent_store.authorized_operations(scope)
persistence.agent_store.exist?(id)
persistence.agent_store.executions.load(id)
persistence.agent_store.send(:participate, scope)
Phronomy::Agent::ExecutionMetadata::TOOL_BATCH_METADATA_KEY
root.journal_position
''')
            self.assertEqual([3, 4, 5, 6], [v['line'] for v in violations(repo)])
            self.assertEqual({'team-reads-agent-internals'}, {v['kind'] for v in violations(repo)})

    def test_handoff_and_subagent_use_the_agent_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / 'lib/phronomy/multi_agent/durable_subagent_coordinator.rb'
            path.parent.mkdir(parents=True)
            path.write_text('Phronomy::Agent::ReservedExecution.new()\nparent.persistence.executions.load(id)\nPhronomy::Agent::ExactExecution.start()\n')
            self.assertEqual([2, 3], [v['line'] for v in violations(repo)])
            path = repo / 'lib/phronomy/agent/execution_change.rb'
            path.parent.mkdir(parents=True)
            path.write_text('Phronomy::MultiAgent::HandoffPolicy.default\n')
            self.assertIn('agent-knows-coordination-domain', {v['kind'] for v in violations(repo)})

    def test_checks_real_calls_including_reflection_but_not_comments_or_owners(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            domain = repo / 'lib/phronomy/tools/agent.rb'
            domain.parent.mkdir(parents=True)
            domain.write_text('''# ctx.__execution_scope and result.complete are comments
x = "ctx.__execution_scope"
ctx.__execution_scope
Execution.send(:__run_async, [])
result.complete(1)
TaskResult.completed(1)
''')
            owner = repo / 'lib/phronomy/execution/internal.rb'
            owner.parent.mkdir(parents=True)
            owner.write_text('ctx.__execution_scope\nresult.complete(1)\n')
            found = violations(repo)
            self.assertEqual([3, 4, 5], [v['line'] for v in found])
            self.assertEqual({'private-execution-control-leak', 'consumer-settles-result'},
                             {v['kind'] for v in found})

    def test_triangles_keep_hidden_evidence_and_separate_band_priority_from_validity(self):
        architecture = {'modules': [{'id': n, 'directory': n} for n in 'ABCD']}
        layout = {'bands': [{'id': 'B' + str(i), 'columns': [[n]]} for i, n in enumerate('ABC', 1)]}
        def edge(a, b, rbs=False):
            return {'from': a, 'to': b, 'references': [] if rbs else [{'file': 'a.rb', 'line': 1}],
                    'requires': [], 'rbs_references': [{'file': 'a.rbs', 'line': 2}] if rbs else []}
        audit = {'commit': 'test', 'module_pairs': [edge('A', 'B'), edge('B', 'C'),
                 edge('A', 'C', True), edge('D', 'B'), edge('D', 'C')]}
        report = analyze(audit, architecture, layout)
        self.assertEqual(2, report['summary']['triangles'])
        self.assertEqual(1, report['summary']['adjacent_bands'])
        first = report['candidates'][0]
        self.assertTrue(first['rbs_only'])
        self.assertEqual('unreviewed', first['review_status'])
        self.assertEqual(audit['module_pairs'][2], first['edges'][-1])
        with tempfile.TemporaryDirectory() as directory:
            write_report(report, directory)
            self.assertEqual(report, json.loads((Path(directory) / 'dependency_triangles.json').read_text()))
            self.assertIn('a.rbs:2', (Path(directory) / 'dependency_triangles.csv').read_text())

    def test_diamond_and_cycles_without_three_distinct_nodes_are_not_triangles(self):
        audit = {'commit': 'test', 'module_pairs': [dict(zip(['from', 'to'], pair))
                 for pair in [('A', 'B'), ('A', 'C'), ('B', 'D'), ('C', 'D'), ('A', 'A'), ('B', 'A')]]}
        report = analyze(audit, {'modules': []}, {'bands': []})
        self.assertEqual([], report['candidates'])
