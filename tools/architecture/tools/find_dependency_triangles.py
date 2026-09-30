"""Review candidates M0->M1, M1->M2, M0->M2, with full Ruby + RBS evidence.

A triangle is NOT an architecture violation. Display bands are a review priority,
not semantic layering rules. Shared contracts and composition roots can be valid.
"""
import argparse
from collections import defaultdict
import csv
import json
from pathlib import Path


def analyze(audit, architecture, layout):
    modules = {m['directory']: m for m in architecture['modules']}
    bands = {identifier: (i, b['id']) for i, b in enumerate(layout['bands'])
             for column in b['columns'] for identifier in column}
    pairs = {(p['from'], p['to']): p for p in audit['module_pairs']}
    graph = defaultdict(set)
    for a, b in pairs:
        if a != b:
            graph[a].add(b)
    def describe(directory):
        module = modules.get(directory, {})
        band = bands.get(module.get('id'))
        return {'directory': directory, 'id': module.get('id'),
                'band': band[1] if band else None}
    findings = []
    for m0 in sorted(graph):
        for m1 in sorted(graph[m0]):
            for m2 in sorted(graph[m0] & graph.get(m1, set())):
                if len({m0, m1, m2}) != 3:
                    continue
                nodes = [describe(m) for m in [m0, m1, m2]]
                positions = [bands.get(n['id'], (None, None))[0] for n in nodes]
                descending = (all(p is not None for p in positions)
                              and positions[0] < positions[1] < positions[2])
                adjacent = (descending and positions[1] == positions[0] + 1
                            and positions[2] == positions[1] + 1)
                direct = pairs[m0, m2]
                kinds = [key for key in ['references', 'requires', 'rbs_references']
                         if direct.get(key)]
                findings.append({'m0': nodes[0], 'm1': nodes[1], 'm2': nodes[2],
                                 'adjacent_bands': bool(adjacent),
                                 'descending_bands': bool(descending),
                                 'direct_evidence_kinds': kinds,
                                 'rbs_only': kinds == ['rbs_references'],
                                 'review_status': 'unreviewed',
                                 'edges': [pairs[m0, m1], pairs[m1, m2], direct]})
    findings.sort(key=lambda f: (not f['adjacent_bands'], not f['descending_bands'],
                                 f['rbs_only'], *(f[k]['directory'] for k in ['m0', 'm1', 'm2'])))
    return {'commit': audit['commit'], 'interpretation': 'Investigation candidates, not violations',
            'graph': 'Full Ruby + RBS union, including arrows hidden only for display',
            'summary': {'triangles': len(findings),
                        'unique_direct_pairs': len({(f['m0']['directory'], f['m2']['directory']) for f in findings}),
                        'adjacent_bands': sum(f['adjacent_bands'] for f in findings),
                        'descending_bands': sum(f['descending_bands'] for f in findings),
                        'rbs_only_triangles': sum(f['rbs_only'] for f in findings)},
            'candidates': findings}


def write_report(report, output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    (output / 'dependency_triangles.json').write_text(json.dumps(report, indent=2) + '\n')
    fields = ['m0', 'm1', 'm2', 'bands', 'adjacent_bands', 'descending_bands',
              'direct_evidence', 'direct_sites', 'review_status']
    with (output / 'dependency_triangles.csv').open('w', newline='') as file:
        writer = csv.DictWriter(file, fieldnames=fields)
        writer.writeheader()
        for f in report['candidates']:
            direct = f['edges'][-1]
            sites = sorted({r['file'] + ':' + str(r['line'])
                            for kind in f['direct_evidence_kinds'] for r in direct[kind]})
            writer.writerow({**{k: f[k]['directory'] for k in ['m0', 'm1', 'm2']},
                             'bands': ' / '.join(f[k]['band'] or 'side' for k in ['m0', 'm1', 'm2']),
                             'adjacent_bands': f['adjacent_bands'],
                             'descending_bands': f['descending_bands'],
                             'direct_evidence': ', '.join(f['direct_evidence_kinds']),
                             'direct_sites': '; '.join(sites), 'review_status': f['review_status']})


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ['audit', 'architecture', 'layout', 'output']:
        parser.add_argument(argument, type=Path)
    args = parser.parse_args()
    result = analyze(*(json.loads(p.read_text()) for p in [args.audit, args.architecture, args.layout]))
    write_report(result, args.output)
    print(json.dumps(result['summary'], indent=2))
