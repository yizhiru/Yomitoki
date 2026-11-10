from pathlib import Path
import json,struct
root=Path(__file__).resolve().parent;corpus=root/'corpus'; manifest=json.loads((root/'manifest-final.json').read_text(encoding='utf-8'))
data=(corpus/'mobi6-uncompressed.mobi').read_bytes();count=struct.unpack_from('>H',data,76)[0]
offsets=[struct.unpack_from('>I',data,78+i*8)[0] for i in range(count)]
original=[bytearray(data[start:(offsets[i+1] if i+1<count else len(data))]) for i,start in enumerate(offsets)]
for recursive in [False,True]:
    name='mobi6-huff-recursive' if recursive else 'mobi6-huff-literal'
    body='HUFF_START 私は静かな喫茶店で本を読んだ。 ALPHA_BETA HUFF_END'
    plain=('<html><head><title>Huff fixture</title></head><body><p>'+body+'</p></body></html>').encode('utf-8')
    records=[bytearray(x) for x in original]
    struct.pack_into('>H',records[0],0,17480);struct.pack_into('>I',records[0],4,len(plain));struct.pack_into('>H',records[0],8,1)
    struct.pack_into('>I',records[0],28,65001);struct.pack_into('>I',records[0],240,0)
    struct.pack_into('>I',records[0],112,count);struct.pack_into('>I',records[0],116,2)
    records[1]=bytearray(plain.replace(b'ALPHA_BETA',b'\xff') if recursive else plain)
    huff=bytearray(b'HUFF'+struct.pack('>III',24,24,1048)+b'\0'*8)
    huff+=struct.pack('>I',(255<<8)|0x80|8)*256
    huff+=b''.join(struct.pack('>II',0,255 if bits==8 else 0) for bits in range(1,33))
    entries=[]
    for i in range(256):
        if recursive and i==0: entries.append(struct.pack('>H',len(b'ALPHA_BETA'))+b'ALPHA_BETA')
        else: entries.append(struct.pack('>H',0x8001)+bytes([255-i]))
    table=bytearray();payload=bytearray();pos=512
    for entry in entries:table+=struct.pack('>H',pos);payload+=entry;pos+=len(entry)
    cdic=b'CDIC'+struct.pack('>III',16,256,8)+table+payload
    records.extend([huff,cdic]);newcount=len(records)
    head=bytearray(data[:78]);struct.pack_into('>H',head,76,newcount)
    head+=b'\0'*(newcount*8)+b'\0\0';pos=len(head)
    for i,record in enumerate(records):struct.pack_into('>II',head,78+i*8,pos,i+1);pos+=len(record)
    dest=corpus/(name+'.mobi');dest.write_bytes(head+b''.join(records))
    manifest.append({'id':name,'file':dest.name,'kind':'MOBI','origin':'controlled-independent-huff-encoder','expected':body,'source':'Self-authored fixed-width HUFF/CDIC dictionary'+(' with a recursive phrase' if recursive else '')})
(root/'manifest-final.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2), encoding='utf-8')
print('Corpus:',len(manifest))
