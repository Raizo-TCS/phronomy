"""Attach resolved RBS evidence to Ruby declaration owners, preserving provenance."""
import json
from pathlib import Path
import subprocess


HERE = Path(__file__).resolve().parent


def extract(root, declarations, singleton_definitions, primary, signature_owners=None):
    result = subprocess.run(
        ['bundle', 'exec', 'ruby', str(HERE / 'extract_rbs.rb'), str(root)],
        cwd=root, check=True, text=True, capture_output=True,
    )
    parsed = json.loads(result.stdout)
    overrides = signature_owners
    if overrides is None:
        overrides = json.loads((HERE.parent / 'config/rbs_owners.json').read_text())
    declared = {d['owner']: d for d in parsed['declarations']}
    directories = {str(Path(d['file']).parent) for ds in declarations.values() for d in ds}
    for name, directory in overrides.items():
        if name not in declared or name in declarations or directory not in directories:
            raise ValueError(f'Invalid RBS-only ownership: {name} -> {directory}')

    def owner(name, reference=None):
        if name in declarations:
            choices = singleton_definitions.get((name, reference['member']), []) if reference and reference['member_kind'] == 'singleton' else []
            if len({d['file'] for d in choices}) > 1:
                raise ValueError(f'Ambiguous Ruby singleton definition: {name}.{reference["member"]}')
            definition = choices[0] if len(choices) == 1 else primary(name)
            return {'directory': str(Path(definition['file']).parent), **definition, 'resolution': 'ruby_declaration'}
        if name in overrides:
            return {'directory': overrides[name], 'file': declared[name]['file'], 'line': declared[name]['line'], 'resolution': 'rbs_only_owner'}
        raise ValueError(f'Missing Ruby declaration / RBS-only owner for {name}')

    ownership = {name: owner(name) for name in declared}
    internal, external = [], []
    for ref in parsed['references']:
        if not (ref['owner'] == 'Phronomy' or ref['owner'].startswith('Phronomy::')):
            raise ValueError(f'Unowned project signature: {ref["owner"]}')
        source = owner(ref['owner'], ref)
        if not (ref['name'] == 'Phronomy' or ref['name'].startswith('Phronomy::')):
            external.append(ref)
            continue
        target = owner(ref['name'])
        internal.append(ref | {
            'from': source['directory'], 'to': target['directory'],
            'source_definition': source, 'target_definition': target,
            'target': target['file'], 'definition_line': target['line'],
            'origin': 'rbs', 'resolution': 'RBS::Environment.resolve_type_names',
        })
    return parsed | {'references': internal, 'external_references': external, 'ownership': ownership}


def integrate(audit, rbs, components):
    directories = {m['directory'] for m in audit['modules']}
    pairs = {(p['from'], p['to']): p for p in audit['module_pairs']}
    refs = [r for r in rbs['references'] if r['from'] in directories and r['to'] in directories]
    for pair in pairs.values():
        pair['rbs_references'] = []
    for ref in refs:
        if ref['from'] == ref['to']:
            continue
        pair = pairs.setdefault((ref['from'], ref['to']), {
            'from': ref['from'], 'to': ref['to'], 'references': [], 'requires': [], 'rbs_references': [],
        })
        pair['rbs_references'].append(ref)
    audit['module_pairs'] = [pairs[key] for key in sorted(pairs)]
    audit['rbs'] = rbs | {'references': refs}
    audit['scope']['rbs_included'] = 'sig/**/*.rbs (including _private); ownership resolved to Ruby modules'
    graphs = {
        'all': set(pairs),
        'ruby': {key for key, p in pairs.items() if p['references'] or p['requires']},
        'rbs': {key for key, p in pairs.items() if p['rbs_references']},
    }
    for kind, edges in graphs.items():
        cycles = components(sorted(directories), edges)
        audit['scc_' + kind] = cycles
        audit['summary']['module_edges'][kind] = len(edges)
        audit['summary']['module_scc_sizes'][kind] = [len(c) for c in cycles if len(c) > 1]
    for module in audit['modules']:
        module['fan_in'] = sum(b == module['directory'] for a, b in pairs)
        module['fan_out'] = sum(a == module['directory'] for a, b in pairs)
    audit['summary'].update(rbs_files=len(rbs['files']), rbs_references=len(refs),
                            rbs_added_pairs=len(graphs['all'] - graphs['ruby']))
    audit['method'] += '; RBS official parser/resolver and declaration ownership; union of Ruby and declared type dependencies'
    return audit
