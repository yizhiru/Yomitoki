"""Compare offline engine time on fixed-length pages; exclude IPC and rendering."""
import json
import math
import statistics
import subprocess
import sys
import time
from pathlib import Path
from run import HERE, ROOT, paragraphs

def main():
    corpus, koe = map(Path, sys.argv[1:])
    stream = '\n'.join(t for name,t,_ in paragraphs(corpus) if name == 'botchan')
    pages = [stream[i:i+800] for i in range(0, len(stream)-799, 800)][:80]
    assert len(set(pages)) == len(pages) == 80
    js = """
      const fs = require('node:fs');
      const {performance} = require('node:perf_hooks');
      const {Dictionary} = require('./desktop/src/dictionary.cjs');
      (async () => {
        const pages = JSON.parse(fs.readFileSync(0,'utf8'));
        const start = performance.now();
        const d = await new Dictionary().load('desktop/.build/resources');
        const times = pages.map(page => {
          const before = performance.now();
          d.readingAnnotations(page,new Set(),true);
          return performance.now() - before;
        });
        console.log(JSON.stringify([performance.now()-start-times.slice(1).reduce((a,b)=>a+b,0),times]));
      })();
    """
    cold, times = json.loads(subprocess.check_output(['node','-e',js],cwd=ROOT,input=json.dumps(pages),text=True))
    def report(name,cold,times):
        warm = sorted(times[1:])
        print(name, 'first (ms)', round(cold,1), 'subsequent median / p95', round(statistics.median(warm),1),
              round(warm[math.ceil(.95*len(warm))-1],1))
    report('Electron',cold,times)
    sys.path.insert(0,str(koe))
    start = time.perf_counter()
    from backend.readings import annotate
    times = []
    for page in pages:
        before = time.perf_counter()
        annotate(page)
        times.append((time.perf_counter()-before)*1000)
        if len(times) == 1:
            cold = (time.perf_counter()-start)*1000
    report('Sudachi',cold,times)

if __name__ == '__main__':
    main()
