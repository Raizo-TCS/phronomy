"""Real RBS resolution, ownership, union evidence and boundary regressions."""
from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parents[1]
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE / 'tools'))
from build_diagram import fingerprint, make_source
from rbs_dependencies import extract
spec = importlib.util.spec_from_file_location('refresh_diagram', HERE / 'refresh_diagram.py')
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)
S = '{http://www.w3.org/2000/svg}'


class ParserTests(unittest.TestCase):
    def parse(self, signature, private=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'sig').mkdir()
            (root / 'sig/example.rbs').write_text(signature)
            if private:
                (root / 'sig/_private').mkdir()
                (root / 'sig/_private/internal.rbs').write_text(private)
            return subprocess.run(['bundle', 'exec', 'ruby', str(HERE / 'tools/extract_rbs.rb'), str(root)],
                                  cwd=REPO, text=True, capture_output=True)

    def test_official_resolution_covers_nested_types_aliases_mixins_and_private_files(self):
        result = self.parse('''module Phronomy
  class Parent
  end
  interface _Contract
    def call: () -> Parent
  end
  module Mixin : _Contract
  end
  type value = Parent | nil
  class Client[A < Parent] < Parent
    include Mixin
    @value: value
    attr_accessor target: _Contract
    def run: [B < Parent] (Array[value], *Parent, keyword: { item: Parent? }, **_Contract) { (singleton(Parent)) -> B } -> ^(Parent) -> Parent
  end
  class Alias = Parent
  module AliasMixin = Mixin
end
''', 'module Phronomy\n  class Internal\n    def call: () -> Parent\n  end\nend\n')
        self.assertEqual(0, result.returncode, result.stderr)
        parsed = json.loads(result.stdout)
        refs = parsed['references']
        self.assertIn('sig/_private/internal.rbs', parsed['files'])
        self.assertEqual({'Phronomy::Parent', 'Phronomy::_Contract', 'Phronomy::Mixin', 'Phronomy::value', 'Array'}, {r['name'] for r in refs})
        self.assertTrue({'type', 'inheritance', 'mixin', 'self_type', 'alias'} <= {r['category'] for r in refs})
        self.assertTrue(all(r['line'] > 0 and r['text'] for r in refs))
        self.assertIn('Phronomy::Internal', {r['owner'] for r in refs})

    def test_unknown_types_and_invalid_syntax_fail_instead_of_dropping_edges(self):
        for signature in ['module Phronomy\n class Client\n def run: () -> Missing\n end\nend\n',
                          'module Phronomy\n invalid @@@\nend\n']:
            with self.subTest(signature=signature):
                result = self.parse(signature)
                self.assertNotEqual(0, result.returncode)
                self.assertTrue(result.stderr)


class ProjectTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory()
        subprocess.run([sys.executable, str(HERE / 'tools/analyze_dependencies.py'), str(REPO), cls.work.name],
                       check=True, stdout=subprocess.DEVNULL)
        cls.audit = json.loads((Path(cls.work.name) / 'module_audit_scoped.json').read_text())
        cls.ruby = json.loads((Path(cls.work.name) / 'module_audit_ruby_scoped.json').read_text())

    @classmethod
    def tearDownClass(cls):
        cls.work.cleanup()

    def test_all_four_clients_reference_contracts_and_engine_without_contract_reverse_edges(self):
        pairs = {(p['from'], p['to']): p for p in self.audit['module_pairs']}
        for feature in ['llm_adapter', 'vector_store', 'vector_store/embeddings', 'storage']:
            base = 'lib/phronomy/' + feature
            with self.subTest(feature=feature):
                pair = pairs[base + '/async', base]
                self.assertTrue(pair['rbs_references'])
                self.assertIn((base + '/async', 'lib/phronomy/engine'), pairs)
                self.assertNotIn((base, base + '/async'), pairs)
                self.assertNotIn((base, 'lib/phronomy/engine'), pairs)
        self.assertEqual(len(pairs), len(self.audit['module_pairs']))
        ruby_pairs = {(p['from'], p['to']) for p in self.ruby['module_pairs']}
        self.assertEqual(ruby_pairs, {key for key, pair in pairs.items() if pair['references'] or pair['requires']})
        self.assertEqual(len(list(REPO.glob('sig/**/*.rbs'))), self.audit['summary']['rbs_files'])

    def test_ownership_follows_declarations_not_legacy_signature_file_directory(self):
        refs = self.audit['rbs']['references']
        client = next(r for r in refs if r['owner'] == 'Phronomy::LLMAdapter::AsyncClient' and r['name'] == 'Phronomy::LLMAdapter::Base')
        self.assertEqual('lib/phronomy/llm_adapter/async', client['from'])
        self.assertEqual('sig/_private/phronomy/llm_adapter/async/async_client.rbs', client['file'])
        aliases = [r for r in refs if r['name'] == 'Phronomy::Storage::resource_ref']
        self.assertTrue(aliases)
        self.assertTrue(all(r['to'] == 'lib/phronomy/storage' for r in aliases))
        configuration = next(r for r in refs if r['owner'] == 'Phronomy' and r['member'] == 'configuration')
        self.assertEqual('lib/phronomy/runtime_composition', configuration['from'])
        self.assertEqual('lib/phronomy/runtime_composition/global_configuration.rb', configuration['source_definition']['file'])

    def test_complete_type_graph_passes_without_a_baseline_and_rejects_reverse_references(self):
        result = refresh.check_boundaries(self.audit, 'storage', REPO)
        self.assertTrue(result['passed'], result)
        self.assertEqual([], result['violations'])
        self.assertFalse((HERE / 'config/rbs_boundary_baseline.json').exists())
        for target in ['lib/phronomy/agent/context_contract', 'lib/phronomy/llm_adapter',
                       'lib/phronomy/runtime_composition']:
            changed = deepcopy(self.audit)
            changed['module_pairs'].append({'from': 'lib/phronomy/configuration', 'to': target,
                                           'references': [], 'requires': [],
                                           'rbs_references': [{'origin': 'rbs'}]})
            with self.subTest(target=target):
                self.assertFalse(refresh.check_boundaries(changed, 'storage', REPO)['passed'])

    def test_svg_keeps_rbs_evidence_and_marks_type_only_matrix_cells(self):
        svg = make_source(self.audit, refresh.read_architecture('storage'), 'TEST_TREE', 'rbs-test', candidate=True)
        root = ET.fromstring(svg)
        meta = json.loads(root.find(S + 'metadata').text)
        edge = next(e for e in meta['edges'] if (e['from'], e['to']) == ('M66', 'M15'))
        self.assertEqual(1, edge['t'])
        self.assertEqual(0, edge['c'] + edge['l'])
        self.assertEqual('rbs', edge['evidence'][0]['origin'])
        matrix = next(n for n in root.iter() if n.get('id') == 'matrix_M66_M15')
        self.assertEqual(['T'], [n.text for n in matrix.iter(S + 'text')])
        self.assertIn('sig/_private/phronomy/llm_adapter/async/async_client.rbs', next(matrix.iter(S + 'title')).text)

    def test_source_fingerprint_covers_private_and_public_signatures(self):
        hashes = fingerprint(REPO)
        self.assertEqual({str(p.relative_to(REPO)) for p in REPO.glob('sig/**/*.rbs')}, {p for p in hashes if p.startswith('sig/')})


if __name__ == '__main__':
    unittest.main()
