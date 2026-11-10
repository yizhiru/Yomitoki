from pathlib import Path
import json,re,hashlib,statistics,platform
root=Path(__file__).resolve().parent
cases=json.loads((root/'manifest-final.json').read_text(encoding='utf-8'));base={x['id']:x for x in json.loads((root/'results.json').read_text(encoding='utf-8'))}
norm=lambda text:re.sub(r'\s+','',text)
summary={'date':'2026-11-09','platform':platform.platform(),'versions':{'calibre':'9.3.1','lingo_epub':'0.4.6','lingo_mobi':'0.4.6','htmlparser2':'10.0.0','foliate_revision':'78914aef4466eb960965702401634c2cb348e9b1','node':'26.8.1','electron':'45.2.3','electron_node':'24.22.2'},'conditions':{'calibre':'exact current imports.cjs TXT conversion flags','lingo':'ESM Node adapter + htmlparser2 text extraction, ruby and inline-hidden removal','foliate':'sandboxed Electron DOM parser + custom encoding/path loader + CSS/HTML text extraction + encryption flag guard','oracle':'self-authored expected body blocks, excluding whitespace; lossy MOBI6 ruby controls are diagnostic only','upstream_check':'40 evenly distributed 64-character paragraph anchors per public book, plus order checks','windows_execution':False},'cases':[]}
for c in cases:
    old=base[c['id']]; entry={k:v for k,v in c.items() if k!='expected'}; entry['has_oracle']=c.get('expected') is not None
    data=(root/'corpus'/c['file']).read_bytes();entry.update({'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'engines':{}})
    baselinePath=root/'results'/(c['id']+'.calibre.txt')
    baseline=baselinePath.read_text(encoding='utf-8') if old['calibre']['ok'] and baselinePath.exists() else ''
    for engine in ['calibre','lingo','foliate']:
        if engine=='calibre':r=dict(old[engine]);text=baseline
        else:
            p=root/'results'/(c['id']+'.'+engine+'.json')
            r=json.loads(p.read_text(encoding='utf-8')) if p.exists() else dict(old[engine]);text=r.pop('text','');r.pop('stack',None)
        r['characters']=len(text);r['nonempty']=bool(text.strip());r['replacement_characters']=text.count('\ufffd');r['text_sha256']=hashlib.sha256(text.encode()).hexdigest()
        if c.get('reject'):r['check_passed']=not r['ok']
        elif c.get('expected') is not None:
            wanted=[norm(s) for s in c['expected'].splitlines() if s.strip()];actual=norm(text)
            r['required_blocks_found']=sum(s in actual for s in wanted);r['required_blocks_total']=len(wanted)
            r['noise_markers']=[s for s in ['HIDDEN_ATTR_PROBE','HIDDEN_INLINE_PROBE','HIDDEN_CSS_PROBE','SCRIPT_PROBE','STYLE_PROBE','METADATA_NOT_BODY'] if s in text]
            markers=re.findall(r'ORDER\d+|LONG\d+_START',c['expected']);positions=[actual.find(s) for s in markers]
            r['order_correct']=all(p>=0 for p in positions) and positions==sorted(positions)
            r['check_passed']=bool(r['ok'] and r['nonempty'] and r['required_blocks_found']==len(wanted) and not r['noise_markers'] and not r['replacement_characters'] and r['order_correct'])
            if c.get('diagnostic_only'):r['matches_calibre_encoded_text']=norm(text)==norm(baseline)
        else:
            paras=[norm(s) for s in re.split(r'\n\s*\n',baseline) if len(norm(s))>=80]
            n=min(40,len(paras));anchors=[paras[round(i*(len(paras)-1)/max(1,n-1))][:64] for i in range(n)]
            positions=[norm(text).find(a) for a in anchors];present=[p for p in positions if p>=0]
            r.update({'anchors_found':len(present),'anchors_total':n,'anchor_order_correct':present==sorted(present)})
            r['check_passed']=bool(r['ok'] and r['nonempty'] and n>0 and len(present)==n and present==sorted(present) and not r['replacement_characters'])
        entry['engines'][engine]=r
    summary['cases'].append(entry)
counts={}
for engine in ['calibre','lingo','foliate']:
    rows=summary['cases'];valid=[r for r in rows if not r.get('reject')];controlled=[r for r in rows if r['has_oracle'] and not r.get('diagnostic_only')];public=[r for r in rows if not r['has_oracle'] and not r.get('reject')];negative=[r for r in rows if r.get('reject')]
    counts[engine]={'valid_nonempty':sum(r['engines'][engine]['ok'] and r['engines'][engine]['nonempty'] for r in valid),'valid_total':len(valid),'controlled_pass':sum(r['engines'][engine]['check_passed'] for r in controlled),'controlled_total':len(controlled),'upstream_pass':sum(r['engines'][engine]['check_passed'] for r in public),'upstream_total':len(public),'anchors_found':sum(r['engines'][engine]['anchors_found'] for r in public),'anchors_total':sum(r['engines'][engine]['anchors_total'] for r in public),'negative_pass':sum(r['engines'][engine]['check_passed'] for r in negative),'negative_total':len(negative)}
summary['counts']=counts
environment=root/'environment.json'
if environment.exists():
    metadata=json.loads(environment.read_text(encoding='utf-8'))
    summary['run_environment']=metadata
    summary['date']=metadata['timestamp_utc'][:10]
    summary['versions']['node']=metadata['node']
    summary['versions']['calibre']=metadata['calibre']
    summary['versions']['electron']=metadata['electron_versions'].get('electron')
    summary['versions']['electron_node']=metadata['electron_versions'].get('node')
summary['conditions']['windows_execution']=platform.system()=='Windows'
(root/'comparison-summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2).replace(str(root),'<evaluation-root>'), encoding='utf-8')
print(json.dumps(counts,ensure_ascii=False,indent=2))
for r in summary['cases']:
    print(r['id'],','.join(e+':'+str(r['engines'][e]['check_passed']) for e in counts), 'diagnostic' if r.get('diagnostic_only') else '')
