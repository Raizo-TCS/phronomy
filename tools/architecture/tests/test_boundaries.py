"""Policy regressions and evidence-preserving rendering, independent of Ruby tests."""
from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parents[1]
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE / 'tools'))
from build_diagram import make_source
from format_dependencies import format_svg
spec = importlib.util.spec_from_file_location('refresh_diagram', HERE / 'refresh_diagram.py')
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)
S = '{http://www.w3.org/2000/svg}'
X = '{http://www.w3.org/1999/xlink}'


class BoundaryTests(unittest.TestCase):
    def setUp(self):
        self.config = refresh.read_architecture('llm')
        self.audit = {
            'commit': 'POLICY_FIXTURE_NOT_ANALYZED_SOURCE',
            'modules': self.config['modules'],
            'module_pairs': [
                {'from': 'lib/phronomy/llm_adapter/async', 'to': 'lib/phronomy/engine'},
                {'from': 'lib/phronomy/llm_adapter/backends', 'to': 'lib/phronomy/llm_adapter'},
                {'from': 'lib/phronomy/storage/backends', 'to': 'lib/phronomy/storage'},
                {'from': 'lib/phronomy/vector_store', 'to': 'lib/phronomy/engine'},
                {'from': 'lib/phronomy/vector_store/embeddings', 'to': 'lib/phronomy/engine'},
            ],
        }

    def check_graph(self, audit=None, config=None):
        return refresh.check_boundaries(audit or self.audit, 'llm', REPO, config or self.config)

    def test_accepts_implemented_llm_boundary_with_declared_vector_work_remaining(self):
        self.assertTrue(self.check_graph()['passed'])

    def test_group_identifiers_and_display_order_do_not_define_policy(self):
        changed = deepcopy(self.config)
        names = {g['id']: 'X' + str(100 - i) for i, g in enumerate(changed['groups'])}
        for group in changed['groups']:
            group['id'] = names[group['id']]
        for module in changed['modules']:
            module['group'] = names[module['group']]
        changed['groups'].reverse()
        changed['modules'].reverse()
        self.assertTrue(self.check_graph(config=changed)['passed'])

    def test_rejects_direct_and_indirect_reverse_dependencies(self):
        for source, target in [
            ('llm_adapter', 'llm_adapter/backends'),
            ('llm_adapter', 'llm_adapter/async'),
            ('llm_adapter', 'engine'),
            ('llm_adapter/backends', 'engine'),
            ('llm_adapter/async', 'llm_adapter/backends'),
            ('llm_adapter/async', 'agent'),
            ('engine', 'llm_adapter/async'),
        ]:
            with self.subTest(source=source, target=target):
                changed = deepcopy(self.audit)
                changed['module_pairs'].append({'from': 'lib/phronomy/' + source, 'to': 'lib/phronomy/' + target})
                self.assertFalse(self.check_graph(changed)['passed'])
        changed = deepcopy(self.audit)
        changed['module_pairs'] += [
            {'from': 'lib/phronomy/llm_adapter', 'to': 'lib/phronomy/common'},
            {'from': 'lib/phronomy/common', 'to': 'lib/phronomy/llm_adapter/backends'},
        ]
        self.assertFalse(self.check_graph(changed)['passed'])

    def test_rejects_implementation_disconnected_from_its_contract(self):
        changed = deepcopy(self.audit)
        changed['module_pairs'] = [p for p in changed['module_pairs'] if p['from'] != 'lib/phronomy/llm_adapter/backends']
        self.assertFalse(self.check_graph(changed)['passed'])

    def test_rejects_unannotated_source_directories(self):
        changed = deepcopy(self.audit)
        changed['modules'].append({'directory': 'lib/phronomy/unreviewed_feature'})
        self.assertFalse(self.check_graph(changed)['passed'])

    def test_rejects_claiming_storage_phase_for_a_partial_llm_graph(self):
        self.assertFalse(refresh.check_boundaries(self.audit, 'storage', REPO)['passed'])


class DiagramTests(unittest.TestCase):
    def test_source_and_candidate_views_preserve_every_edge_matrix_cell_and_module(self):
        audit = json.loads((HERE / 'evidence/baseline/module_audit_scoped.json').read_text())
        architecture = refresh.read_architecture('baseline')
        count = len(audit['modules'])
        edge_count = len(audit['module_pairs'])
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            for candidate in [False, True]:
                with self.subTest(candidate=candidate):
                    source = make_source(audit, architecture, 'BASELINE_TREE_FIXTURE', 'render-test', candidate=candidate)
                    (work / 'source.svg').write_bytes(source)
                    format_svg(work / 'source.svg', work / 'result.svg', HERE / 'config/baseline.layout.json')
                    root = ET.parse(work / 'result.svg').getroot()
                    metadata = json.loads(root.find(S + 'metadata').text)
                    self.assertEqual(count, len(metadata['modules']))
                    self.assertEqual(edge_count, len(metadata['edges']))
                    self.assertEqual(edge_count, len(list(root.iter(S + 'polygon'))))
                    hidden = [e for e in metadata['edges'] if e['to'] in {'M33', 'M41', 'M44'}]
                    arrows = [n for n in root.iter(S + 'g') if n.get('class') == 'edge']
                    self.assertEqual(len(hidden), sum(n.get('display') == 'none' for n in arrows))
                    nodes = next(n for n in root.iter() if n.get('id') == 'module-nodes')
                    self.assertTrue(all(n.get('fill') == 'none' for n in nodes.iter(S + 'rect')))
                    self.assertEqual(count ** 2, sum(n.get('class') == 'matrix-cell' for n in root.iter()))
                    links = [n.get(X + 'href') for n in root.iter(S + 'a') if n.get(X + 'href')]
                    self.assertEqual(0 if candidate else 2 * edge_count + count, len(links))
                    self.assertEqual(candidate, metadata['candidate'])
                    self.assertEqual(not candidate, metadata['source_links_enabled'])

    def test_annotation_must_assign_each_module_exactly_once(self):
        audit = json.loads((HERE / 'evidence/baseline/module_audit_scoped.json').read_text())
        for invalid in ['missing', 'duplicate', 'old-rank']:
            config = refresh.read_architecture('baseline')
            if invalid == 'missing':
                config['groups'][0]['members'].pop()
            elif invalid == 'duplicate':
                config['groups'][0]['members'].append(config['groups'][0]['members'][0])
            else:
                config['modules'][0]['rank'] = 1
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                make_source(audit, config, 'TREE', 'invalid')


if __name__ == '__main__':
    unittest.main()
