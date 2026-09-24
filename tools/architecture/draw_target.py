#!/usr/bin/env python3
"""Draw the proposed backend structure in the original per-directory module-box style.

Standard library only. This is a proposed, scoped diagram, not an AST result.
Module IDs follow config/group-registry.json and the implementation plan.
"""
import argparse
import json
import math
from pathlib import Path
import xml.etree.ElementTree as ET
S='{http://www.w3.org/2000/svg}'
X='{http://www.w3.org/1999/xlink}'
ET.register_namespace('',S[1:-1]);ET.register_namespace('xlink',X[1:-1])
SHA='84668606523e8b013ccb1cf1144694ecd28f24f8'
WIDTH,HEIGHT=3260,2370
BW,BH=380,140

def build():
    root=ET.Element(S+'svg',{'width':str(WIDTH),'height':str(HEIGHT),'viewBox':f'0 0 {WIDTH} {HEIGHT}','role':'img','aria-labelledby':'chart-title chart-description'})
    def add(tag,parent=None,text=None,**attrs):
        e=ET.SubElement(root if parent is None else parent,S+tag,{k.replace('_','-'):str(v) for k,v in attrs.items()});e.text=text;return e
    def text(x,y,value,size=20,color='#294353',parent=None,**attrs):
        return add('text',parent,value,x=x,y=y,font_size=size,fill=color,font_family='DejaVu Sans, sans-serif',**attrs)
    add('title',text='Phronomy proposed architecture: individual module boxes',id='chart-title')
    add('desc',text='Proposed responsibilities, preserving the original white module boxes, thin blue borders, directory labels and stable module IDs. G numbers do not express hierarchy. Arrows represent planned module dependencies or group-level composition, not measured AST edges.',id='chart-description')
    metadata=add('metadata')
    add('rect',x=0,y=0,width=WIDTH,height=HEIGHT,fill='#ffffff')
    add('style',text='.edge:hover path{stroke-opacity:1;stroke-width:3}.edge:hover polygon{fill-opacity:1}.node:hover rect{stroke:#365f7b;stroke-width:2.5}')
    text(70,75,'PHRONOMY 0.27.0',42,font_weight=750)
    text(70,123,'TARGET ARCHITECTURE / RESPONSIBILITY GROUPS',29)
    text(70,168,'MODULE BOXES / revision 3 / 2026-09-24  |  PROPOSED — NOT IMPLEMENTED',23,'#876033')
    text(70,207,'Baseline commit: '+SHA,19)
    text(70,246,'One box per source module. Thin outer frames show responsibility groups; group IDs and coordinates imply no hierarchy.',21)
    text(70,285,'Solid arrows: planned module dependencies. Dashed arrows: group-level selection / injection. Common dependencies are omitted for focus.',19,'#526b7a')
    text(70,322,'21 core modules + 3 external example modules. This scope is separate from the complete, measured source dependency diagram.',19,'#526b7a')
    frames=add('g',id='responsibility-groups')
    def frame(gid,x,y,w,h,title,subtitle=None,dashed=False):
        g=add('g',frames,id='group-'+gid)
        add('rect',g,x=x,y=y,width=w,height=h,rx=10,fill='none',stroke='#c4d1db',stroke_width=1.3,stroke_dasharray='6 5' if dashed else 'none')
        text(x+14,y+28,title,19,'#526e80',g,font_weight=650)
        if subtitle:text(x+14,y+56,subtitle,15,'#627988',g)
    frame('composition',80,450,480,665,'COMPOSITION — SELECTED MODULES','Separate owners: G39 / G35 / G24')
    frame('G46',770,450,520,1165,'G46  ASYNC CLIENTS','Feature namespaces; no common Async namespace')
    frame('G47',1480,450,520,1410,'G47  BACKEND CONTRACTS','Synchronous SPI / values / errors / common rules')
    frame('G14',80,1200,480,720,'G14  ENGINE','Generic execution / no feature-specific backend logic')
    frame('G48',2210,450,960,1590,'G48  BACKEND IMPLEMENTATIONS','Production code. Implementations depend on Contracts.')
    text(2250,563,'CORE REPOSITORY',17,'#526e80',font_weight=650)
    frame('examples',2705,700,430,1265,'EXAMPLES REPOSITORY','Display IDs EX01–EX03; excluded from core AST',True)
    modules={}
    def module(mid,gid,x,y,directory,role,footer,external=False):
        modules[mid]={'id':mid,'group':gid,'center':[x,y],'directory':directory,'role':role,'footer':footer,'external':external}
    module('M54','G39',320,640,'agent/composition','Agent / one-shot composition','Existing owner / selected scope')
    module('M51','G35',320,840,'runtime_composition','Defaults / runtime bindings','Existing owner / selected scope')
    module('M39','G24',320,1040,'persistence_composition','Repositories over a storage view','Existing owner / selected scope')
    module('M11','G14',320,1370,'engine','Runtime / EventLoop / TaskResult','Existing execution services')
    module('M12','G14',320,1590,'engine/concurrency','OffloadPool / cancellation / composition','Existing concurrency services')
    module('M13','G14',320,1810,'engine/runtime','Timer / shutdown helpers','Existing runtime helpers')
    for mid,y,directory,role in [
        ('M66',640,'llm_adapter/async','LLMAdapter::AsyncClient'),
        ('M67',1080,'vector_store/async','VectorStore::AsyncClient'),
        ('M68',1300,'vector_store/embeddings/async','VectorStore::Embeddings::AsyncClient'),
        ('M69',1520,'storage/async','Storage::AsyncClient')]:
        module(mid,'G46',1030,y,directory,role,'Planned directory / existing feature namespace')
    text(840,815,'Synchronous backend + Engine',17,'#627988')
    text(840,845,'Admission / offload / TaskResult',17,'#627988')
    for mid,y,directory,role in [
        ('M15',640,'llm_adapter','Synchronous LLM adapter SPI'),
        ('M47',860,'llm_contract','LLM errors / token usage'),
        ('M28',1080,'vector_store','Synchronous vector store SPI'),
        ('M29',1300,'vector_store/embeddings','Synchronous embedding SPI'),
        ('M34',1520,'storage','Records / Streams / Blobs / transaction'),
        ('M10',1740,'content_store','ContentStore SPI / storage schema')]:
        module(mid,'G47',1740,y,directory,role,'No Engine / AsyncClient / concrete backend dependency')
    for mid,y,directory,role,footer in [
        ('M70',640,'llm_adapter/backends','LLMAdapter::RubyLLM','Planned directory / public constant preserved'),
        ('M71',1080,'vector_store/backends','InMemory / Pgvector / RedisSearch','Planned directory / public constants preserved'),
        ('M72',1300,'vector_store/embeddings/backends','Embeddings::RubyLLMEmbeddings','Planned directory / public constant preserved'),
        ('M35',1520,'storage/backends','Storage::Backends::InMemory','Existing directory / namespace preserved'),
        ('M73',1740,'content_store/backends','ContentStore::StoredContents','Planned directory / public constant preserved')]:
        module(mid,'G48',2470,y,directory,role,footer)
    module('EX01','G48',2920,920,'shared/storage','PhronomyExamples::Storage::Backend','Shared backend implementation / examples',True)
    module('EX02','G48',2920,1350,'30_sqlite_persistence/lib','Persistence::ActiveRecordSQLite','Concrete SQLite backend / examples',True)
    module('EX03','G48',2920,1780,'31_postgresql_persistence/lib','Persistence::ActiveRecordPostgreSQL','Concrete PostgreSQL backend / examples',True)
    edges=add('g',id='planned-dependencies');records=[]
    def path(points,source,target,kind='planned-module',relation='uses'):
        g=add('g',edges,id='edge-'+source+'-'+target,**{'class':'edge'})
        add('title',g,text=f'{source} → {target}: {relation}; proposed, not measured AST evidence')
        d='M '+' L '.join(f'{x:g} {y:g}' for x,y in points)
        add('path',g,d=d,fill='none',stroke='#427c98',stroke_width=1.7,stroke_opacity=.62,stroke_linejoin='round',stroke_dasharray='6 5' if kind=='composition' else 'none')
        end=points[-1];prev=points[-2]
        # Module paths end at hidden centers, but the visible tip stops at the boundary.
        if target in modules:
            cx,cy=end;dx,dy=prev[0]-cx,prev[1]-cy
            scale=min((BW/2)/abs(dx) if dx else math.inf,(BH/2)/abs(dy) if dy else math.inf)
            tip=(cx+dx*scale,cy+dy*scale)
        else:tip=end
        dx,dy=end[0]-prev[0],end[1]-prev[1];norm=math.hypot(dx,dy);ux,uy=dx/norm,dy/norm
        tip=(tip[0]-ux*1.6,tip[1]-uy*1.6)
        base=(tip[0]-ux*13,tip[1]-uy*13)
        add('polygon',g,points=f'{tip[0]:.2f},{tip[1]:.2f} {base[0]-uy*5:.2f},{base[1]+ux*5:.2f} {base[0]+uy*5:.2f},{base[1]-ux*5:.2f}',fill='#427c98',fill_opacity=.9)
        records.append({'from':source,'to':target,'kind':kind,'relation':relation})
    def direct(a,b):path([modules[a]['center'],modules[b]['center']],a,b)
    for a,b in [('M66','M15'),('M67','M28'),('M68','M29'),('M69','M34'),('M70','M15'),('M71','M28'),('M72','M29'),('M35','M34'),('M73','M10'),('M15','M47'),('M10','M34'),('M11','M12'),('M11','M13')]:
        if (a,b)==('M11','M13'):
            path([(320,1370),(112,1370),(112,1810),(320,1810)],a,b)
        else:direct(a,b)
    for i,mid in enumerate(['M66','M67','M68','M69']):
        sx,sy=modules[mid]['center'];tx,ty=modules['M11']['center'];gx=690-24*i;offset=-30+20*i
        path([(sx,sy),(gx,sy),(gx,ty+offset),(tx+BW/2+28,ty+offset),(tx,ty)],mid,'M11',relation='obtains Engine execution services')
    path([(2470,1740),(2110,1740),(2110,1544),(1960,1544),(1740,1520)],'M73','M34',relation='uses Storage view and errors')
    path([(2920,920),(2675,920),(2675,1630),(2080,1630),(2080,1557),(1960,1557),(1740,1520)],'EX01','M34',relation='implements Storage::Backend')
    path([(2920,1350),(2920,990),(2920,920)],'EX02','EX01',relation='inherits shared backend')
    path([(2920,1780),(3145,1780),(3145,945),(3130,945),(2920,920)],'EX03','EX01',relation='inherits shared backend')
    path([(560,515),(770,515)],'composition','G46','composition','supplies selected backend')
    path([(320,450),(320,365),(2690,365),(2690,450)],'composition','G48','composition','selects / constructs implementations')
    text(592,498,'injects',15,'#526b7a')
    text(2290,352,'selects / constructs',16,'#526b7a')
    nodes=add('g',id='module-nodes')
    for mid,m in modules.items():
        cx,cy=m['center'];x,y=cx-BW/2,cy-BH/2
        node=add('g',nodes,id='node-'+mid,**{'class':'node'})
        add('title',node,text=f"{mid} / {m['group']} / {m['directory']} / {m['role']} / proposed scoped diagram")
        add('rect',node,x=x,y=y,width=BW,height=BH,rx=9,fill='#ffffff',stroke='#7896aa',stroke_width=1.7)
        text(x+14,y+25,mid+'   |   '+m['group'],18,parent=node,font_weight=750)
        lines=[];line=''
        for segment in m['directory'].split('/'):
            candidate=line+'/'+segment if line else segment
            if len(candidate)>29 and line:lines.append(line+'/');line=segment
            else:line=candidate
        lines.append(line)
        assert len(lines)<=2,(mid,lines)
        for i,label in enumerate(lines):text(x+14,y+53+i*23,label,19,parent=node,font_weight=650)
        text(x+14,y+102,m['role'],13,'#526b7a',node)
        text(x+14,y+125,m['footer'],11.8,'#627988',node)
    text(70,2125,'HOW TO READ THIS CONCEPT',25,font_weight=750)
    notes=[
        'The original module-box style is preserved: stable IDs, directory names, individual white boxes, thin group frames and solid triangular arrowheads.',
        'G14 Engine, G46 Async Clients, G47 Backend Contracts and G48 Backend Implementations are independent responsibilities; there are no numbered layers.',
        'Solid arrows show selected planned dependencies, including contract use through injection. They are not a complete prediction of future Ruby AST edges.',
        'The selected composition modules are shown for context; dashed arrows apply to composition as a responsibility, not to every module inside its frame.',
        'EX01–EX03 belong to phronomy-examples. Other domain modules, common definitions, document processing and token budget are outside this focused view.',
    ]
    for i,value in enumerate(notes):text(70,2170+i*33,value,18,'#526b7a')
    metadata.text=json.dumps({'status':'PROPOSED_NOT_IMPLEMENTED','diagram_revision':'module-boxes-r3-20260924','baseline_commit':SHA,'visual_style':'original per-directory white module boxes / thin group frames','group_number_semantics':'identifiers only; no layers or ranks','modules':list(modules.values()),'edges':records,'group_relations':[['composition','G46'],['composition','G48'],['G46','G14'],['G46','G47'],['G48','G47']],'source_scope':'Selected planned relationships, separate from measured full AST diagram'},ensure_ascii=False)
    assert len(modules)==24 and sum(not m['external'] for m in modules.values())==21
    assert len(list(root.iter(S+'polygon')))==len(records)
    return ET.tostring(root,encoding='utf-8',xml_declaration=True)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=Path(__file__).with_name('phronomy-async-bridge-target-20260924.svg'))
    args=parser.parse_args();args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_bytes(build());print(args.output)

if __name__=='__main__':main()
