import {EPUB} from './foliate-js/epub.js';
import {MOBI} from './foliate-js/mobi.js';
import {unzipSync, unzlibSync} from './node_modules/fflate/esm/browser.js';
const blocks = new Set(['p','div','h1','h2','h3','h4','h5','h6','li','section','article','blockquote','pre','tr','dt','dd']);
function plain(doc, stylesheets = []) {
    // Parse CSS without attaching book HTML to the app or fetching resources.
    const hidden = new WeakSet();
    for(const css of [...stylesheets,...Array.from(doc.querySelectorAll('style'),s=>s.textContent)]) {
        try {
            const sheet=new CSSStyleSheet();sheet.replaceSync(css);
            for(const rule of sheet.cssRules) {
                if(rule.selectorText && (rule.style?.display==='none' || rule.style?.visibility==='hidden')) {
                    try { for(const node of doc.querySelectorAll(rule.selectorText)) hidden.add(node); } catch {}
                }
            }
        } catch {}
    }
    function visit(node) {
        if(node.nodeType===3) return node.nodeValue;
        const name=node.localName?.toLowerCase();
        if(['head','script','style','rt','rp','title','noscript'].includes(name) || hidden.has(node)) return '';
        if(node.nodeType===1 && (node.hasAttribute('hidden') || node.getAttribute('aria-hidden')==='true' || /(?:^|;)\s*(?:display\s*:\s*none|visibility\s*:\s*hidden)/i.test(node.getAttribute('style')||''))) return '';
        if(name==='br' || name==='pagebreak') return '\n\n';
        const text=Array.from(node.childNodes).map(visit).join('');
        return blocks.has(name) ? '\n\n'+text+'\n\n' : text;
    }
    return visit(doc).replace(/\r/g,'').replace(/[\t \u00a0]+/g,' ').replace(/ *\n */g,'\n').replace(/\n{3,}/g,'\n\n').trim();
}
function decoder(data) {
    const prelude=new TextDecoder().decode(data.slice(0,512));
    const encoding=prelude.match(/encoding\s*=\s*["']([^"']+)/i)?.[1] || prelude.match(/charset\s*=\s*["']?([^\s"';>]+)/i)?.[1] || 'utf-8';
    return new TextDecoder(encoding).decode(data);
}
const cases=await window.evaluation.cases();
for(const test of cases) {
    const started=performance.now();let book;
    try {
        const bytes=new Uint8Array(await window.evaluation.bytes(test.id));
        let files, loadText;
        if(test.kind==='EPUB') {
            files=unzipSync(bytes);
            const find=name=>files[name] || files[decodeURIComponent(name)];
            loadText=name=>{const data=find(name);return data ? decoder(data) : undefined;};
            book=await new EPUB({loadText,loadBlob:name=>{const data=find(name);return data?new Blob([data]):undefined;},getSize:name=>find(name)?.length || 0}).init();
        } else {
            if(bytes.length<100) throw new Error('Truncated MOBI header');
            const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
            const record0=view.getUint32(78);
            if(record0+40>bytes.length) throw new Error('Truncated MOBI header');
            if(view.getUint16(record0+12)!==0) throw new Error('DRM encrypted MOBI');
            book=await new MOBI({unzlib:unzlibSync}).open(new File([bytes],test.file));
        }
        const texts=[];
        for(const section of book.sections) {
            const doc=await section.createDocument();
            if(doc.querySelector('parsererror')) throw new Error('Chapter XML parse error: '+section.id);
            const styles=[];
            if(loadText) for(const link of doc.querySelectorAll('link[rel~="stylesheet"][href]')) {
                const base=new URL(section.id,'https://ebook.invalid/');
                const resolved=new URL(link.getAttribute('href'),base);
                const css=loadText(decodeURIComponent(resolved.pathname.slice(1)));
                if(css) styles.push(css);
            }
            texts.push(plain(doc,styles));
        }
        await window.evaluation.result(test.id,{ok:true,sections:book.sections.length,text:texts.join('\n\n'),milliseconds:performance.now()-started});
    } catch(e) {
        await window.evaluation.result(test.id,{ok:false,error:e.message,stack:e.stack,milliseconds:performance.now()-started});
    } finally {try {book?.destroy();} catch {}}
}
window.evaluation.done();
