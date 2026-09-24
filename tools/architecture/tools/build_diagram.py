#!/usr/bin/env python3
"""Run the preserved Phronomy analyzer and connect fresh evidence to the SVG formatter."""
import argparse
from collections import Counter
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

from format_dependencies import format_svg

HERE = Path(__file__).resolve().parent
S = '{http://www.w3.org/2000/svg}'
X = '{http://www.w3.org/1999/xlink}'
ET.register_namespace('', S[1:-1])
ET.register_namespace('xlink', X[1:-1])


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()


def fingerprint(repo):
    return {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted((repo / 'lib').rglob('*.rb'))}


def anchor(parent, url, title):
    attributes = {'target': '_blank'}
    if url:
        attributes[X + 'href'] = url
    a = ET.SubElement(parent, S + 'a', attributes)
    ET.SubElement(a, S + 'title').text = title
    return a


def make_source(audit, architecture, tree, revision, candidate=False):
    modules = deepcopy(architecture['modules'])
    if any('layer' in m or 'rank' in m for m in modules):
        raise ValueError('Use responsibility groups without layer/rank fields')
    bydir = {m['directory']: m for m in modules}
    byid = {m['id']: m for m in modules}
    if len(bydir) != len(modules) or len(byid) != len(modules):
        raise ValueError('Duplicate module directory or ID in architecture.json')
    actual = {m['directory'] for m in audit['modules']}
    if actual != set(bydir):
        raise ValueError('Update architecture.json and layout.json for the changed module set; '
                         f'added={sorted(actual - set(bydir))}, removed={sorted(set(bydir) - actual)}')
    order = architecture['matrix_order']
    if len(order) != len(modules) or set(order) != set(byid):
        raise ValueError('matrix_order must contain every module ID exactly once')
    groups = architecture['groups']
    if len({g['id'] for g in groups}) != len(groups):
        raise ValueError('Duplicate ownership group ID')
    memberships = [mid for g in groups for mid in g['members']]
    if set(memberships) != set(byid) or any(n > 1 for n in Counter(memberships).values()):
        raise ValueError('Unknown or duplicate ownership group member')
    if any(byid[mid]['group'] != g['id'] for g in groups for mid in g['members']):
        raise ValueError('Group annotation and membership disagree')
    cycles = [c for c in audit['scc_all'] if len(c) > 1]
    for found in audit['modules']:
        item = bydir[found['directory']]
        item.update({k: v for k, v in found.items() if k != 'id'})
        item['scc_group'] = next((i + 1 for i, c in enumerate(cycles) if item['directory'] in c), None)
        item['scc'] = item['scc_group'] is not None
    root = ET.Element(S + 'svg', {'width': '3260', 'height': '6800'})
    metadata = ET.SubElement(root, S + 'metadata')
    eg = ET.SubElement(root, S + 'g', {'id': 'source-evidence-edges'})
    ng = ET.SubElement(root, S + 'g', {'id': 'module-nodes'})
    repository = architecture['repository_url'].rstrip('/')
    commit = audit['commit']
    edges, proofs = [], {}
    for pair in audit['module_pairs']:
        a, b = bydir[pair['from']], bydir[pair['to']]
        direction = 'internal' if a['group'] == b['group'] else 'external'
        refs, requires = pair['references'], pair['requires']
        proof = (refs or requires)[0]
        edge = {'from': a['id'], 'to': b['id'], 'direction': direction, 'c': len(refs), 'l': len(requires),
                'exception_only': bool(refs) and not requires and all(p['category'] == 'error' for p in refs)}
        edges.append(edge)
        url = f"{repository}/blob/{commit}/{proof['file']}#L{proof['line']}"
        title = f"{a['id']} -> {b['id']}; C={len(refs)}, L={len(requires)}; {direction}; {proof['file']}:{proof['line']}"
        proofs[a['id'], b['id']] = (None if candidate else url, title)
        anchor(ET.SubElement(eg, S + 'g', {'id': f"edge_{a['id']}_{b['id']}"}), None if candidate else url, title)
    for item in modules:
        anchor(ET.SubElement(ng, S + 'g', {'id': 'node_' + item['id']}),
               None if candidate else f"{repository}/tree/{commit}/{item['directory']}", item['directory'])

    matrix = ET.SubElement(root, S + 'g', {'id': 'dependency-matrix'})
    def text(x, y, value, size=18, **kwargs):
        el = ET.SubElement(matrix, S + 'text', {'x': str(x), 'y': str(y), 'font-size': str(size),
                           'fill': '#294353', 'font-family': 'DejaVu Sans, sans-serif', **kwargs})
        el.text = value
    text(70, 4210, 'COMPLETE DEPENDENCY MATRIX', 28)
    instruction = 'Hover a cell for source evidence; GitHub links disabled.' if candidate else 'Hover or click a cell for source evidence.'
    text(70, 4249, 'Rows: source. Columns: target. C = constant reference; L = require; + = both. ' + instruction, 19)
    cell, x0, y0 = 31, 790, 4360
    colors = {'internal': '#76808d', 'external': '#427c98'}
    emap = {(e['from'], e['to']): e for e in edges}
    for j, mid in enumerate(order):
        x = x0 + j * cell + cell / 2
        text(x, 4348, mid, 14, transform=f'rotate(-60 {x} 4348)')
    for i, f in enumerate(order):
        y = y0 + i * cell
        text(70, y + 22, f + '  ' + byid[f]['directory'].removeprefix('lib/phronomy/'), 16)
        for j, t in enumerate(order):
            x = x0 + j * cell
            group = ET.SubElement(matrix, S + 'g', {'id': f'matrix_{f}_{t}', 'class': 'matrix-cell'})
            ET.SubElement(group, S + 'rect', {'x': str(x), 'y': str(y), 'width': str(cell), 'height': str(cell),
                          'fill': 'none', 'stroke': '#dde6eb', 'stroke-width': '0.6'})
            if (f, t) not in emap:
                continue
            edge = emap[f, t]
            a = anchor(group, *proofs[f, t])
            ET.SubElement(a, S + 'rect', {'x': str(x + 3), 'y': str(y + 3), 'width': str(cell - 6),
                          'height': str(cell - 6), 'rx': '4', 'fill': colors[edge['direction']]})
            el = ET.SubElement(a, S + 'text', {'x': str(x + cell / 2), 'y': str(y + 22), 'font-size': '16',
                              'fill': '#fff', 'text-anchor': 'middle', 'font-family': 'DejaVu Sans, sans-serif'})
            el.text = '+' if edge['c'] and edge['l'] else 'C' if edge['c'] else 'L'
    footer = f'Source: fresh Ruby AST analysis. Diagram revision: {revision} | ARCHITECTURE LABELS FROM CONFIGURATION.'
    if candidate:
        footer += ' | LOCAL CANDIDATE / SOURCE LINKS DISABLED'
    y = y0 + len(order) * cell + 46
    for i, value in enumerate([footer, f'Analyzed commit: {commit}', f'Source tree: {tree}',
                              f"{len(modules)} modules / {len(groups)} responsibility groups / {len(edges)} pairs."]):
        text(70, y + i * 32, value)
    meta = {'repository': repository, 'commit': commit, 'source_tree': tree, 'source_modified': False,
            'candidate': candidate, 'source_links_enabled': not candidate, 'scope': audit['scope'], 'stats': audit['summary'], 'modules': modules, 'groups': groups, 'edges': edges,
            'analyzer_to_diagram_ids': {m['id']: bydir[m['directory']]['id'] for m in audit['modules']},
            'diagram_revision': revision, 'project_title': architecture['project_title'],
            'diagram_subtitle': ('LOCAL CANDIDATE / NOT APPLIED / source links disabled' if candidate else 'Ruby source analysis / architecture labels from configuration'),
            'commit_label': 'Local candidate commit: ' if candidate else 'Analyzed commit: ', 'matrix_footer': footer,
            'view_label': 'Fresh static source analysis; architecture annotations supplied separately',
            'architecture_note': 'Responsibility groups are supplied annotations. IDs and coordinates have no order or abstraction rank.',
            'annotation_source_commit': architecture['annotation_source_commit'],
            'annotation_source_revision': architecture['annotation_source_revision'],
            'verification_method': 'Fresh execution of preserved analyzer; evidence and SCC regenerated from Ruby sources'}
    metadata.text = json.dumps(meta, ensure_ascii=False)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository', type=Path)
    parser.add_argument('output_directory', type=Path)
    parser.add_argument('--architecture', type=Path, default=HERE / 'architecture.json')
    parser.add_argument('--layout', type=Path, default=HERE / 'layout.json')
    parser.add_argument('--revision', help='Default: source-<commit prefix>')
    parser.add_argument('--candidate', action='store_true', help='Unpublished local snapshot: disable GitHub links')
    args = parser.parse_args()
    repo, output = args.repository.resolve(), args.output_directory.resolve()
    if not (repo / 'lib/phronomy').is_dir():
        raise ValueError('Expected a Phronomy checkout with lib/phronomy')
    head, tree = git(repo, 'rev-parse', 'HEAD'), git(repo, 'rev-parse', 'HEAD^{tree}')
    if git(repo, 'status', '--porcelain', '--', 'lib'):
        raise ValueError('SVG source links require committed lib sources. Use analyze_dependencies.py alone for uncommitted changes.')
    before = fingerprint(repo)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.dependency-build-', dir=output) as temporary:
        work = Path(temporary)
        subprocess.run([sys.executable, str(HERE / 'analyze_dependencies.py'), str(repo), str(work)], check=True)
        audit = json.loads((work / 'module_audit_scoped.json').read_text())
        if audit['commit'] != head or audit['source_changed']:
            raise ValueError('Source changed during analysis')
        architecture = json.loads(args.architecture.read_text())
        layout = json.loads(args.layout.read_text())
        revision = args.revision or 'source-' + head[:8]
        layout['diagram_revision'] = revision
        (work / 'source.svg').write_bytes(make_source(audit, architecture, tree, revision, candidate=args.candidate))
        (work / 'layout.json').write_text(json.dumps(layout, indent=2) + '\n')
        format_svg(work / 'source.svg', work / 'dependencies.svg', work / 'layout.json', work / 'validation.json')
        if before != fingerprint(repo) or git(repo, 'rev-parse', 'HEAD') != head or git(repo, 'status', '--porcelain', '--', 'lib'):
            raise ValueError('Source changed during diagram generation')
        (work / 'source_sha256.json').write_text(json.dumps(before, indent=2) + '\n')
        for path in sorted(work.iterdir()):
            path.replace(output / path.name)
    print('Generated:', output / 'dependencies.svg')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
