from pathlib import Path
import subprocess,os,json,hashlib,struct,shutil
root=Path(__file__).resolve().parent;corpus=root/'corpus'; manifest=json.loads((root/'manifest-final.json').read_text(encoding='utf-8'))
calibre=os.environ['CALIBRE_BIN'];env=dict(os.environ,CALIBRE_CONFIG_DIRECTORY=str(root/'calibre-config'))
for name,kind in [('mobi6-spine-order','old'),('mobi8-spine-order','new')]:
    src=corpus/'epub2-spine-order.epub';dest=corpus/(name+'.mobi')
    p=subprocess.run([calibre,str(src),str(dest),'--mobi-file-type',kind],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=env,timeout=60)
    (root/(name+'-generation.log')).write_bytes(p.stdout)
    if p.returncode:raise RuntimeError(p.stdout.decode(errors='replace')[-500:])
    manifest.append({'id':name,'file':dest.name,'kind':'MOBI','origin':'controlled-calibre-encoded','expected':next(x['expected'] for x in manifest if x['id']=='epub2-spine-order'),'source':'Calibre 9.3.1 encoder from epub2-spine-order.epub'})
# Explicitly mark lossy conversion controls; original ruby structure is already absent from MOBI 6 source.
for case in manifest:
    if case['id'] in ['mobi6-japanese','mobi6-uncompressed']:
        case['oracle_note']='Original EPUB ruby semantics were flattened by the MOBI6 encoder; diagnostic reference only, not a decoder defect.'
        case['diagnostic_only']=True
# Independent MOBI 6 encoding variant: uncompressed, one CP1252 text record.
base=corpus/'mobi6-uncompressed.mobi';data=base.read_bytes();count=struct.unpack_from('>H',data,76)[0]
offsets=[struct.unpack_from('>I',data,78+i*8)[0] for i in range(count)]
records=[bytearray(data[start:(offsets[i+1] if i+1<count else len(data))]) for i,start in enumerate(offsets)]
text='<html><head><title>CP1252</title></head><body><h1>Encodage</h1><p>LATIN_START café Müller — naïve “résumé” LATIN_END</p></body></html>'.encode('cp1252')
struct.pack_into('>H',records[0],0,1);struct.pack_into('>I',records[0],4,len(text));struct.pack_into('>H',records[0],8,1)
struct.pack_into('>I',records[0],28,1252);struct.pack_into('>I',records[0],240,0)
records[1]=bytearray(text);head=bytearray(data[:offsets[0]]);pos=len(head)
for i,rec in enumerate(records):struct.pack_into('>I',head,78+i*8,pos);pos+=len(rec)
dest=corpus/'mobi6-windows1252.mobi';dest.write_bytes(head+b''.join(records))
manifest.append({'id':'mobi6-windows1252','file':dest.name,'kind':'MOBI','origin':'controlled-reencoded','expected':'Encodage\nLATIN_START café Müller — naïve “résumé” LATIN_END','source':'Independent uncompressed CP1252 text record with rebuilt PDB offsets'})
repo=root/'jsebook'
revision=subprocess.check_output([shutil.which('git'),'-C',str(repo),'rev-parse','HEAD'],text=True).strip()
for file in ['data/testbook.mobi','data/testbook-images.mobi']:
    data=subprocess.check_output([shutil.which('git'),'-C',str(repo),'show','HEAD:'+file],timeout=60)
    dest=corpus/('independent-'+Path(file).name);dest.write_bytes(data)
    start=int.from_bytes(data[78:82],'big');print(file,'compression',int.from_bytes(data[start:start+2],'big'),'bytes',len(data),flush=True)
    manifest.append({'id':dest.stem,'file':dest.name,'kind':'MOBI','origin':'independent-upstream-sample','expected':None,'source':'https://github.com/daviddrysdale/jsebook/blob/'+revision+'/'+file,'sha256':hashlib.sha256(data).hexdigest()})
(root/'manifest-final.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2), encoding='utf-8')
print('Extended to',len(manifest),'cases',flush=True)
