import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from check_abstractions import violations
from find_dependency_triangles import analyze, write_report


class AbstractionTests(unittest.TestCase):
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
