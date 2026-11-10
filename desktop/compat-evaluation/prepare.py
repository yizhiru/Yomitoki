import zipfile,json,html,os,subprocess,hashlib,urllib.request,urllib.parse,time
from pathlib import Path
root=Path(__file__).resolve().parent; corpus=root/'corpus';corpus.mkdir(exist_ok=True)
calibre=os.environ['CALIBRE_BIN']
env=dict(os.environ,CALIBRE_CONFIG_DIRECTORY=str(root/'calibre-config'))
manifest=[]
def epub(name, chapters, version='3.0', encoding='utf-8', css='', paths=None):
    paths=paths or ['chapter'+str(i)+'.xhtml' for i in range(len(chapters))]
    ns='http://www.idpf.org/2007/opf'
    nav='<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol>'+''.join('<li><a href="'+urllib.parse.quote(path)+'">Chapter '+str(i+1)+'</a></li>' for i,path in enumerate(paths))+'</ol></nav></body></html>'
    opf=f'<?xml version="1.0" encoding="utf-8"?><package xmlns="{ns}" version="{version}" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:{name}</dc:identifier><dc:title>{name}</dc:title><dc:language>ja</dc:language><meta property="dcterms:modified">2026-01-01T00:00:00Z</meta></metadata><manifest>'+''.join(f'<item id="c{i}" href="{urllib.parse.quote(path)}" media-type="application/xhtml+xml"/>' for i,path in enumerate(paths))+'<item id="css" href="style.css" media-type="text/css"/>'+(('<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>') if version=='3.0' else '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')+'</manifest><spine'+(' toc="ncx"' if version!='3.0' else '')+'>'+''.join(f'<itemref idref="c{i}"/>' for i in range(len(chapters)))+'</spine></package>'
    ncx='<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head/><docTitle><text>'+name+'</text></docTitle><navMap>'+''.join(f'<navPoint id="n{i}" playOrder="{i+1}"><navLabel><text>Chapter {i+1}</text></navLabel><content src="{urllib.parse.quote(path)}"/></navPoint>' for i,path in enumerate(paths))+'</navMap></ncx>'
    dest=corpus/(name+'.epub')
    with zipfile.ZipFile(dest,'w') as z:
        z.writestr('mimetype','application/epub+zip',compress_type=zipfile.ZIP_STORED)
        z.writestr('META-INF/container.xml','<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        z.writestr('OEBPS/content.opf',opf)
        z.writestr('OEBPS/style.css',css)
        z.writestr('OEBPS/nav.xhtml',nav)
        z.writestr('OEBPS/toc.ncx',ncx)
        for path,(body,expected) in reversed(list(zip(paths,chapters))):
            text=f'<?xml version="1.0" encoding="{encoding}"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>METADATA_NOT_BODY</title><link rel="stylesheet" type="text/css" href="'+('../' if '/' in path else '')+'style.css"/></head><body>'+body+'</body></html>'
            z.writestr('OEBPS/'+path,text.encode(encoding),compress_type=zipfile.ZIP_DEFLATED)
    manifest.append({'id':name,'file':dest.name,'kind':'EPUB','origin':'controlled','expected':'\n\n'.join(x[1] for x in chapters),'source':'self-authored controlled fixture'})
    return dest
base=epub('epub2-spine-order',[(f'<h1>第{i}章</h1><p>ORDER{i}：'+x+'</p>',f'第{i}章\nORDER{i}：'+x) for i,x in enumerate(['朝、私は駅へ歩いた。','昼、喫茶店で本を読んだ。','夜、家に帰った。'],1)],version='2.0',paths=['z.xhtml','a.xhtml','m.xhtml'])
ruby=epub('epub3-japanese-ruby', [('<h1>日本語の読書</h1><p>JPSTART 雨が上がったので、傘を閉じて小さな<ruby><rb>喫茶店</rb><rp>（</rp><rt>きっさてん</rt><rp>）</rp></ruby>に入った。</p><p><ruby>東京<rt>とうきょう</rt></ruby>で<ruby>本<rt>ほん</rt></ruby>を読む。JPEND</p>', '日本語の読書\nJPSTART 雨が上がったので、傘を閉じて小さな喫茶店に入った。\n東京で本を読む。JPEND')])
epub('epub3-encoded-path-unicode', [('<h1>道と名前</h1><p>UNICODE_START 𠮷野さんは「café Müller」で𩸽を注文した。A&amp;B &lt;C&gt; ① Ａ UNICODE_END</p>', '道と名前\nUNICODE_START 𠮷野さんは「café Müller」で𩸽を注文した。A&B <C> ① Ａ UNICODE_END')],paths=['日本語 空白/本文.xhtml'])
latin=epub('epub2-windows1252', [('<h1>Encodage</h1><p>LATIN_START café Müller — naïve “résumé” LATIN_END</p>','Encodage\nLATIN_START café Müller — naïve “résumé” LATIN_END')],version='2.0',encoding='windows-1252')
epub('epub3-hidden-and-script', [('<h1>可視本文</h1><p>VISIBLE_START 読むべき本文。<span hidden="hidden">HIDDEN_ATTR_PROBE</span><span style="display:none">HIDDEN_INLINE_PROBE</span><span class="invisible">HIDDEN_CSS_PROBE</span>終わり。VISIBLE_END</p><script>globalThis.SCRIPT_PROBE = true;</script><style>.STYLE_PROBE {color:red}</style>', '可視本文\nVISIBLE_START 読むべき本文。終わり。VISIBLE_END')],css='.invisible {display:none;}')
epub('epub3-ruby-many-chapters', [(f'<h1>第{i}章</h1><p>LONG{i}_START '+('私は静かな喫茶店で本を読み、窓の外を見た。'*250)+f' LONG{i}_END</p>',f'第{i}章\nLONG{i}_START '+('私は静かな喫茶店で本を読み、窓の外を見た。'*250)+f' LONG{i}_END') for i in range(1,31)])
(root/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2), encoding='utf-8')
for name,src,kind,extra in [('mobi6-japanese',ruby,'old',[]),('mobi6-uncompressed',ruby,'old',['--dont-compress']),('mobi8-japanese',ruby,'new',[]),('mobi-combo-japanese',ruby,'both',[]),('mobi6-latin',latin,'old',[])]:
    dest=corpus/(name+'.mobi'); log=root/(name+'-generation.log')
    start=time.perf_counter()
    with log.open('w') as out:
        try:
            p=subprocess.run([calibre,str(src),str(dest),'--mobi-file-type',kind,*extra],env=env,stdout=out,stderr=subprocess.STDOUT,timeout=90)
            print('Generated',name,p.returncode,round(time.perf_counter()-start,2),flush=True)
            if p.returncode==0:
                source=next(x for x in manifest if x['file']==src.name)
                manifest.append({'id':name,'file':dest.name,'kind':'MOBI','origin':'controlled-calibre-encoded','expected':source['expected'],'source':'Calibre 9.3.1 encoder from '+src.name})
        except Exception as e: print('Generation error',name,repr(e),flush=True)
    (root/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2), encoding='utf-8')
# Public-domain works from parser authors' examples. No commercial book samples.
for filename in ['alice-ori.epub','alice-corner-case.epub','Alices-Adventures.mobi','sample-mobi-files-Around-the-World.mobi','mobiLang.mobi']:
    url='https://raw.githubusercontent.com/hhk-png/lingo-reader/720914c1339499761d82dc68077ab521f6dafb55/example/'+urllib.parse.quote(filename)
    try:
        req=urllib.request.Request(url,headers={'User-Agent':'Yomitoki-import-compat-evaluation'})
        with urllib.request.urlopen(req,timeout=35) as response: data=response.read(20_000_001)
        if len(data)>20_000_000: raise ValueError('Sample exceeded 20MB limit')
        dest=corpus/('upstream-'+filename);dest.write_bytes(data)
        manifest.append({'id':'upstream-'+Path(filename).stem,'file':dest.name,'kind':dest.suffix[1:].upper(),'origin':'upstream-public-sample','expected':None,'source':url,'sha256':hashlib.sha256(data).hexdigest()})
        print('Downloaded',filename,len(data),flush=True)
    except Exception as e: print('Download failed',filename,repr(e),flush=True)
    (root/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2), encoding='utf-8')
if len(manifest)!=16: raise RuntimeError('Incomplete sample corpus; inspect prepare log')
print('Prepared',len(manifest),'cases',flush=True)
