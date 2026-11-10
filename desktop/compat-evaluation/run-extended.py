import os,json,subprocess,time,hashlib,re,shutil,collections
from pathlib import Path
root=Path(__file__).resolve().parent;corpus=root/'corpus'; out=root/'results';out.mkdir(exist_ok=True)
manifest=json.loads((root/'manifest-final.json').read_text(encoding='utf-8'))
env=dict(os.environ,CALIBRE_CONFIG_DIRECTORY=str(root/'calibre-config'))
calibre=os.environ['CALIBRE_BIN'];node=os.environ['NODE_BIN']
compact=lambda s:re.sub(r'\s+','',s)
rows=json.loads((root/'results.json').read_text(encoding='utf-8'))
for case in manifest:
    if any(row['id']==case['id'] for row in rows): continue
    file=corpus/case['file']; row={'id':case['id'],'file':case['file'],'kind':case['kind'],'origin':case['origin'],'bytes':file.stat().st_size,'sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'source':case['source']}
    for engine in ['lingo','calibre']:
        dest=out/(case['id']+'.'+engine+('.json' if engine=='lingo' else '.txt'))
        cmd=[node,str(root/'lingo-worker.mjs'),str(file),str(dest)] if engine=='lingo' else [calibre,str(file),str(dest),'--txt-output-formatting','plain','--max-line-length','0','--txt-output-encoding','utf-8','--newline','unix']
        started=time.perf_counter()
        try:
            p=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=env,timeout=45)
            (out/(case['id']+'.'+engine+'.log')).write_bytes(p.stdout)
            status={'ok':p.returncode==0,'wall_ms':round((time.perf_counter()-started)*1000,2)}
            if engine=='lingo':
                result=json.loads(dest.read_text(encoding='utf-8')) if dest.exists() else {'error':p.stdout.decode(errors='replace')[-700:]}
                status.update({k:v for k,v in result.items() if k not in ['text','stack']});text=result.get('text','')
            else:
                text=dest.read_text(encoding='utf-8') if p.returncode==0 and dest.exists() else ''
                if p.returncode: status['error']=p.stdout.decode(errors='replace')[-700:]
            status['characters']=len(text);status['replacement_characters']=text.count('\ufffd')
            if case.get('reject'):status['expected_rejection']=not status['ok']
            elif case['expected'] is not None and status['ok']:
                wanted=[compact(x) for x in case['expected'].splitlines() if x.strip()];actual=compact(text)
                status['required_blocks_found']=sum(x in actual for x in wanted);status['required_blocks_total']=len(wanted)
                status['missing_blocks']=[x[:110] for x in wanted if x not in actual]
                status['ruby_readings_present']=[x for x in ['きっさてん','とうきょう','ほん'] if x in text]
                status['noise_markers']=[x for x in ['HIDDEN_ATTR_PROBE','HIDDEN_INLINE_PROBE','HIDDEN_CSS_PROBE','SCRIPT_PROBE','STYLE_PROBE','METADATA_NOT_BODY'] if x in text]
                markers=re.findall(r'ORDER\d+|LONG\d+_START',case['expected'])
                positions=[actual.find(x) for x in markers]
                status['order_correct']=all(x>=0 for x in positions) and positions==sorted(positions)
            row[engine]=status
        except subprocess.TimeoutExpired:
            row[engine]={'ok':False,'error':'Timeout after 45 seconds','wall_ms':round((time.perf_counter()-started)*1000,2)}
        print(case['id'],engine,json.dumps(row[engine],ensure_ascii=False),flush=True)
    rows.append(row)
    (root/'results.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2), encoding='utf-8')
print('Completed',len(rows),'cases',flush=True)
