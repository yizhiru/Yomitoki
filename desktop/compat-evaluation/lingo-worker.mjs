import fs from 'node:fs/promises';
import path from 'node:path';
import {performance} from 'node:perf_hooks';
import {parseDocument} from 'htmlparser2';
import {initEpubFile} from '@lingo-reader/epub-parser';
import {initMobiFile, initKf8File} from '@lingo-reader/mobi-parser';

const [file, output, forced] = process.argv.slice(2);
const begin = performance.now();
const blocks = new Set(['p','div','h1','h2','h3','h4','h5','h6','li','section','article','blockquote','pre','tr','dt','dd']);
function extract(html) {
    const doc = parseDocument(html, {decodeEntities:true});
    function visit(node) {
        if (node.type === 'text') return node.data;
        if (['head','script','style','rt','rp','title','noscript'].includes(node.name)) return '';
        const a=node.attribs || {};
        if ('hidden' in a || a['aria-hidden']==='true' || /(?:^|;)\s*(?:display\s*:\s*none|visibility\s*:\s*hidden)/i.test(a.style || '')) return '';
        if (node.name === 'br' || node.name === 'mbp:pagebreak') return '\n\n';
        const text=(node.children || []).map(visit).join('');
        return blocks.has(node.name) ? '\n\n'+text+'\n\n' : text;
    }
    return visit(doc).replace(/\r/g,'').replace(/[\t \u00a0]+/g,' ').replace(/ *\n */g,'\n').replace(/\n{3,}/g,'\n\n').trim();
}
function mobiInfo(data) {
    if (data.length < 100) throw new Error('Truncated PDB');
    const records=data.readUInt16BE(76);const start=data.readUInt32BE(78);
    if (start+40>data.length) throw new Error('Truncated MOBI header');
    const info={records, compression:data.readUInt16BE(start), encryption:data.readUInt16BE(start+12), version:data.readUInt32BE(start+36), encoding:data.readUInt32BE(start+28)};
    let exth=start+16+data.readUInt32BE(start+20);
    if (exth+12<data.length && data.toString('ascii',exth,exth+4)==='EXTH') {
        const count=data.readUInt32BE(exth+8);let pos=exth+12;
        for(let i=0;i<count && pos+8<=data.length;i++) {
            const type=data.readUInt32BE(pos), length=data.readUInt32BE(pos+4);
            if(length<8 || pos+length>data.length) break;
            if(type===121 && length>=12) info.boundary=data.readUInt32BE(pos+8);
            pos+=length;
        }
    }
    return info;
}
let book;
try {
    const resources=output+'.resources';await fs.mkdir(resources,{recursive:true});
    const kind=path.extname(file).toLowerCase();
    let info=null, method;
    if(kind==='.epub') { method='epub'; book=await initEpubFile(file,resources); }
    else {
        info=mobiInfo(await fs.readFile(file));
        if(info.encryption) throw new Error('DRM encrypted MOBI');
        method=forced || ((info.version>=8 || (info.boundary>0 && info.boundary<info.records)) ? 'kf8':'mobi');
        book=await (method==='kf8' ? initKf8File : initMobiFile)(file,resources);
    }
    const spine=book.getSpine();
    const sections=[];let rawCharacters=0;
    for(const entry of spine) {
        const chapter=await book.loadChapter(entry.id);
        const raw=chapter?.html ?? entry.text;
        if(typeof raw!=='string') throw new Error('No HTML for '+entry.id);
        rawCharacters+=raw.length;
        sections.push(extract(raw));
    }
    const result={ok:true, method, info, sections:spine.length, rawCharacters, text:sections.join('\n\n'), milliseconds:performance.now()-begin};
    try { book.destroy(); } catch(e) { result.cleanupError=e.message; }
    await fs.writeFile(output,JSON.stringify(result));
    console.log(JSON.stringify({ok:true,method,info,sections:spine.length,characters:result.text.length,milliseconds:result.milliseconds}));
} catch(e) {
    await fs.writeFile(output,JSON.stringify({ok:false,error:e.message,stack:e.stack,milliseconds:performance.now()-begin}));
    console.log(JSON.stringify({ok:false,error:e.message}));
    process.exitCode=1;
}
