from pathlib import Path
import json,subprocess,os,hashlib
root=Path(__file__).resolve().parent;out=root/'results'; rows=[]
electron=os.environ['ELECTRON_BIN']
for c in json.loads((root/'manifest-final.json').read_text(encoding='utf-8')):
    dest=out/(c['id']+'.electron-node.json')
    p=subprocess.run([electron,str(root/'lingo-worker.mjs'),str(root/'corpus'/c['file']),str(dest)],env=dict(os.environ,ELECTRON_RUN_AS_NODE='1'),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
    first=out/(c['id']+'.lingo.json')
    r=json.loads(dest.read_text(encoding='utf-8')) if dest.exists() else {'ok':False,'error':'child process exited without result'}
    old=json.loads(first.read_text(encoding='utf-8')) if first.exists() else {'ok':False}
    rows.append({'id':c['id'],'ok':r.get('ok',False),'matches_node26_status':r.get('ok',False)==old.get('ok',False),'matches_node26_text':r.get('text')==old.get('text'),'text_sha256':hashlib.sha256(r.get('text','').encode()).hexdigest()})
(root/'electron-node-results.json').write_text(json.dumps(rows,indent=2), encoding='utf-8')
print('Embedded Electron Node:',len(rows),'cases; identical status/text to Node26:',sum(r['matches_node26_status'] and r['matches_node26_text'] for r in rows))
