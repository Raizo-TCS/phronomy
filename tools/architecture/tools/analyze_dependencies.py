"""Directory-level, evidence-preserving static review of the fixed Phronomy tree."""
import json, sys, re, argparse, subprocess
from pathlib import Path
from collections import defaultdict, Counter
from tree_sitter import Language, Parser
import tree_sitter_ruby

arguments = argparse.ArgumentParser(description=__doc__)
arguments.add_argument('repository')
arguments.add_argument('output_directory')
args = arguments.parse_args()
ROOT = Path(args.repository).resolve()
HERE = Path(args.output_directory).resolve()
HERE.mkdir(parents=True, exist_ok=True)
commit = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
source_changed = bool(subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain', '--', 'lib', 'sig'], text=True))
parser=Parser(Language(tree_sitter_ruby.language()))
sources={str(p.relative_to(ROOT)):p.read_bytes() for p in sorted(ROOT.glob('lib/**/*.rb'))}
trees={f:parser.parse(b) for f,b in sources.items()}
decls=defaultdict(list); uses=[]; requires=[]; parents={}; current=b''
singleton_definitions=defaultdict(list)

def text(n): return current[n.start_byte:n.end_byte].decode() if n is not None else ''
def children(n):
    yield n
    for c in n.named_children: yield from children(c)
def qualify(name,scopes):
    if name.startswith('::'):return name[2:]
    if name.startswith('Phronomy::'):return name
    return scopes[-1]+'::'+name if scopes else name
def is_descendant(n,ancestor):
    return ancestor is not None and ancestor.start_byte<=n.start_byte and n.end_byte<=ancestor.end_byte
def scan(n,f,scopes=(),method=None):
    if n.type in ('class','module'):
        name=qualify(text(n.child_by_field_name('name')),scopes)
        decls[name].append({'file':f,'line':n.start_point.row+1,'kind':n.type})
        sup=n.child_by_field_name('superclass')
        if sup:
            cs=[x for x in sup.named_children if x.type in ('constant','scope_resolution')]
            if cs:parents[name]=(text(cs[0]),scopes)
            scan(sup,f,scopes,method)
        body=n.child_by_field_name('body')
        if body:scan(body,f,scopes+(name,),method)
        return
    if n.type=='assignment':
        left=n.child_by_field_name('left')
        if left and left.type in ('constant','scope_resolution'):
            decls[qualify(text(left),scopes)].append({'file':f,'line':left.start_point.row+1,'kind':'assignment'})
            right=n.child_by_field_name('right')
            if right:scan(right,f,scopes,method)
            return
    if n.type in ('method','singleton_method'):
        method=text(n.child_by_field_name('name'))
        if n.type == 'singleton_method' and text(n.child_by_field_name('object')) == 'self' and scopes:
            singleton_definitions[(scopes[-1], method)].append({'file':f,'line':n.start_point.row+1})
        elif n.type == 'method' and scopes:
            ancestor = n.parent
            while ancestor and ancestor.type not in ('class', 'module', 'singleton_class', 'method', 'singleton_method'):
                ancestor = ancestor.parent
            if ancestor and ancestor.type == 'singleton_class' and text(ancestor.child_by_field_name('value')) == 'self':
                singleton_definitions[(scopes[-1], method)].append({'file':f,'line':n.start_point.row+1})
    if n.type=='call' and text(n.child_by_field_name('method')) in ('require','require_relative'):
        a=n.child_by_field_name('arguments')
        arg=a.named_children[0] if a and a.named_children else None
        if arg and arg.type=='string' and not any(x.type=='interpolation' for x in children(arg)):
            requires.append({'file':f,'line':n.start_point.row+1,'call':text(n.child_by_field_name('method')),'path':text(arg)[1:-1],'method':method})
    if n.type in ('constant','scope_resolution'):
        use={'file':f,'line':n.start_point.row+1,'text':text(n),'scopes':scopes,'method':method,'syntax':'reference','receiver_method':None}
        p=n.parent
        if p and p.type=='superclass':use['syntax']='inheritance'
        elif p and p.type=='call' and p.child_by_field_name('receiver')==n:
            m=text(p.child_by_field_name('method'))
            use['syntax']='construction' if m=='new' else 'call'
            use['receiver_method']=m
        elif p and p.type=='argument_list' and p.parent and p.parent.type=='call':
            m=text(p.parent.child_by_field_name('method'))
            if m in ('include','extend','prepend'):use['syntax']='mixin'
            elif m in ('is_a?','kind_of?','instance_of?'):use['syntax']='type_test'
        uses.append(use)
        return
    for c in n.named_children:scan(c,f,scopes,method)

for f,t in trees.items():
    current=sources[f]
    assert not t.root_node.has_error,f
    scan(t.root_node,f)

def direct(name,scopes):
    candidates=[name[2:]] if name.startswith('::') else [s+'::'+name for s in reversed(scopes)]+[name]
    return next((c for c in candidates if c in decls),None)
def resolve(name,scopes):
    result=direct(name,scopes)
    if result:return result,'lexical'
    # Resolve unqualified inherited constants only when a static superclass is known.
    if '::' not in name:
        for scope in reversed(scopes):
            visited=set();owner=scope
            while owner in parents and owner not in visited:
                visited.add(owner)
                p,ss=parents[owner];owner=direct(p,ss)
                if not owner:break
                k=owner+'::'+name
                if k in decls:return k,'inherited'
    return None,None
def primary(k):
    # Responsibility roots can reopen a namespace in shorter paths. Use its
    # canonical definition rather than a shortest-path reopening.
    canonical = {
        'Phronomy::Agent': 'lib/phronomy/agent/api/agent.rb',
        'Phronomy::Workflow': 'lib/phronomy/workflow/execution/workflow.rb',
        'Phronomy::Persistence': 'lib/phronomy/persistence/api/persistence.rb',
    }
    if k in canonical:
        matches = [d for d in decls[k] if d['file'] == canonical[k]]
        assert len(matches) == 1, (k, matches)
        return matches[0]
    return min(decls[k],key=lambda x:(x['file'].count('/'),len(x['file']),x['line']))
def error_class(k):
    seen=set()
    while k and k not in seen:
        seen.add(k)
        if k in ('Exception','StandardError'):return True
        if k not in parents:return False
        p,ss=parents[k]
        if p.lstrip(':') in ('Exception','StandardError'):return True
        k=direct(p,ss)
    return False

references=[];unresolved=[];external_namespace_references=[]
for u in uses:
    k,resolution=resolve(u['text'],u['scopes'])
    if not k:
        unresolved.append({k:v for k,v in u.items() if k!='scopes'})
        continue
    if k != 'Phronomy' and not k.startswith('Phronomy::'):
        external_namespace_references.append({a:b for a,b in u.items() if a!='scopes'}|{'constant':k})
        continue
    d=primary(k)
    # These public singleton APIs have owners different from their namespace
    # reopening. Resolve the actual AST definition, including a moved run_once.
    if (k, u['receiver_method']) in {('Phronomy', 'configuration'), ('Phronomy::Agent', 'run_once')}:
        definitions = singleton_definitions[(k, u['receiver_method'])]
        assert len(definitions) == 1, (k, u['receiver_method'], definitions)
        d = definitions[0]
    category=u['syntax']
    if error_class(k):category='error'
    elif k=='Phronomy' and u['receiver_method']=='configuration':category='configuration'
    elif category=='reference':category='value_or_type'
    references.append({k:v for k,v in u.items() if k!='scopes'}|{'constant':k,'target':d['file'],'definition_line':d['line'],'category':category,'resolution':resolution})

internal_requires=[];external_requires=[]
for r in requires:
    dest=(ROOT/r['file']).parent/r['path'] if r['call']=='require_relative' else ROOT/'lib'/r['path']
    dest=dest.resolve()
    if dest.suffix!='.rb':dest=dest.with_suffix('.rb')
    if dest.is_file() and dest.is_relative_to(ROOT):internal_requires.append(r|{'target':str(dest.relative_to(ROOT))})
    else:external_requires.append(r)

modules=sorted(set(str(Path(f).parent) for f in sources))
ids={m:'M%02d'%i for i,m in enumerate(modules)}
def group(f):return str(Path(f).parent)
def scc(edges,nodes=modules):
    graph={n:set() for n in nodes}
    for a,b in edges:graph.setdefault(a,set()).add(b);graph.setdefault(b,set())
    indexes={};low={};stack=[];on=set();out=[]
    def visit(v):
        indexes[v]=low[v]=len(indexes);stack.append(v);on.add(v)
        for w in sorted(graph[v]):
            if w not in indexes:visit(w);low[v]=min(low[v],low[w])
            elif w in on:low[v]=min(low[v],indexes[w])
        if low[v]==indexes[v]:
            c=[]
            while True:
                w=stack.pop();on.remove(w);c.append(w)
                if w==v:break
            out.append(sorted(c))
    for v in sorted(graph):
        if v not in indexes:visit(v)
    return sorted(out,key=lambda x:(-len(x),x))

pairs=defaultdict(lambda:{'references':[],'requires':[]})
for r in references:
    a,b=group(r['file']),group(r['target'])
    if a!=b:pairs[(a,b)]['references'].append(r)
for r in internal_requires:
    a,b=group(r['file']),group(r['target'])
    if a!=b:pairs[(a,b)]['requires'].append(r)

constant_edges={p for p,v in pairs.items() if v['references']}
load_edges={p for p,v in pairs.items() if v['requires']}
behavior_edges={p for p,v in pairs.items() if any(r['category'] not in ('error','configuration') for r in v['references'])}

stats=[]
for m in modules:
    fs=[f for f in sources if group(f)==m]
    stats.append({'id':ids[m],'directory':m,'files':fs,'file_count':len(fs),'lines':sum(len(sources[f].splitlines()) for f in fs),'fan_out':len({b for a,b in pairs if a==m}),'fan_in':len({a for a,b in pairs if b==m}),'reference_fan_out':len({b for a,b in constant_edges if a==m}),'reference_fan_in':len({a for a,b in constant_edges if b==m}),'behavior_fan_out':len({b for a,b in behavior_edges if a==m}),'behavior_fan_in':len({a for a,b in behavior_edges if b==m})})

out={'commit':commit,'source_changed':source_changed,'method':'directory mapping, lexical and statically known inherited constant resolution; declarations excluded; injected calls reviewed separately','modules':stats,'references':references,'internal_requires':internal_requires,'external_requires':external_requires,'external_namespace_references':external_namespace_references,'unresolved':unresolved,'module_pairs':[{'from':a,'to':b,**v} for (a,b),v in sorted(pairs.items())],'scc_all':scc(pairs),'scc_constants':scc(constant_edges),'scc_requires':scc(load_edges),'scc_behavior':scc(behavior_edges),'file_scc_constants':scc({(r['file'],r['target']) for r in references if r['file']!=r['target']},nodes=list(sources))}
(HERE/'module_audit.json').write_text(json.dumps(out,indent=2))

# Filter out lib directly and preserve the scoped evidence.
"""Filter the fixed AST evidence; lib/phronomy.rb is outside the review graph."""
from pathlib import Path
from collections import Counter
import copy, json, sys

raw = json.loads((HERE / 'module_audit.json').read_text())
d = copy.deepcopy(raw)
excluded = {'lib/phronomy.rb'}
d['scope'] = {'included': 'lib/phronomy/**/*.rb', 'excluded_files': sorted(excluded),
              'excluded_module': 'M00', 'source_changed': source_changed}
d['modules'] = [m for m in d['modules'] if m['directory'] != 'lib']
d['module_pairs'] = [p for p in d['module_pairs'] if p['from'] != 'lib' and p['to'] != 'lib']
for key in ['references', 'internal_requires']:
    d[key] = [r for r in d[key] if r['file'] not in excluded and r['target'] not in excluded]

def components(nodes, pairs):
    adjacent = {n: set() for n in nodes}
    for a, b in pairs:
        adjacent[a].add(b)
    stack, index, low, active, result = [], {}, {}, set(), []
    def visit(n):
        index[n] = low[n] = len(index)
        stack.append(n); active.add(n)
        for v in sorted(adjacent[n]):
            if v not in index:
                visit(v); low[n] = min(low[n], low[v])
            elif v in active:
                low[n] = min(low[n], index[v])
        if low[n] == index[n]:
            group = []
            while True:
                v = stack.pop(); active.remove(v); group.append(v)
                if v == n: break
            result.append(sorted(group))
    for n in sorted(nodes):
        if n not in index: visit(n)
    return sorted(result, key=lambda c: (-len(c), c))

dirs = [m['directory'] for m in d['modules']]
graphs = {
    'all': {(p['from'], p['to']) for p in d['module_pairs']},
    'constants': {(p['from'], p['to']) for p in d['module_pairs'] if p['references']},
    'requires': {(p['from'], p['to']) for p in d['module_pairs'] if p['requires']},
    'behavior': {(p['from'], p['to']) for p in d['module_pairs']
                 if any(r['category'] not in ('error', 'configuration') for r in p['references'])},
}
for label, graph in graphs.items():
    d['scc_' + label] = components(dirs, graph)
for m in d['modules']:
    for label, prefix in [('all', ''), ('constants', 'reference_'), ('behavior', 'behavior_')]:
        graph = graphs[label]
        m[prefix+'fan_in'] = len({a for a,b in graph if b == m['directory']})
        m[prefix+'fan_out'] = len({b for a,b in graph if a == m['directory']})
files = [f for m in d['modules'] for f in m['files']]
file_c = {(r['file'],r['target']) for r in d['references'] if r['file'] != r['target']}
file_l = {(r['file'],r['target']) for r in d['internal_requires'] if r['file'] != r['target']}
d['file_scc_constants'] = components(files, file_c)
file_to_module = {f:m['id'] for m in d['modules'] for f in m['files']}
root_refs = [r for r in d['references']
             if file_to_module[r['target']] == 'M01' and file_to_module[r['file']] != 'M01']
summary = {
    'modules': len(dirs), 'files': len(files), 'lines': sum(m['lines'] for m in d['modules']),
    'module_edges': {k:len(v) for k,v in graphs.items()},
    'module_scc_sizes': {k:[len(c) for c in d['scc_'+k] if len(c)>1] for k in graphs},
    'file_edges': {'constants':len(file_c), 'requires':len(file_l)},
    'file_scc_sizes': [len(c) for c in d['file_scc_constants'] if len(c)>1],
    'root_incoming_occurrences': len(root_refs),
    'root_incoming_categories': dict(Counter(r['category'] for r in root_refs)),
    'excluded_module_pairs':len(raw['module_pairs'])-len(d['module_pairs']),
}
# Count methods and non-comment lines in precisely the scoped source files.
from tree_sitter import Language, Parser
import tree_sitter_ruby
parser = Parser(Language(tree_sitter_ruby.language()))
def count_defs(node):
    return int(node.type in ('method', 'singleton_method')) + sum(count_defs(c) for c in node.named_children)
summary['methods'] = sum(count_defs(trees[f].root_node) for f in files)
summary['nonblank_noncomment_lines'] = sum(sum(bool(line.strip()) and not line.lstrip().startswith(b'#') for line in sources[f].splitlines()) for f in files)
d['summary'] = summary
(HERE/'module_audit_ruby_scoped.json').write_text(json.dumps(d, ensure_ascii=False, indent=2)+'\n')
from rbs_dependencies import extract, integrate
rbs = extract(ROOT, decls, singleton_definitions, primary)
(HERE/'rbs_audit.json').write_text(json.dumps(rbs, ensure_ascii=False, indent=2)+'\n')
d = integrate(d, rbs, components)
summary = d['summary']
(HERE/'module_audit_scoped.json').write_text(json.dumps(d, ensure_ascii=False, indent=2)+'\n')
(HERE/'module_summary_scoped.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2)+'\n')
print(json.dumps(summary, ensure_ascii=False, indent=2))
