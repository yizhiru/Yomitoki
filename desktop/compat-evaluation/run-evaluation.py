"""Run an isolated comparison. Requires developer Node, existing Electron, and Calibre."""
import argparse,os,sys,subprocess,shutil,json,datetime
from pathlib import Path
ROOT=Path(__file__).resolve().parent
FOLIATE='78914aef4466eb960965702401634c2cb348e9b1'
JSEBOOK='851b9708b4cd940bacfcf17cc363af79fa17bf75'

def run(command,env,log=None):
    print('Running:', ' '.join(map(str,command)),flush=True)
    if log:
        with (ROOT/log).open('w',encoding='utf-8') as out:subprocess.run(command,cwd=ROOT,env=env,check=True,stdout=out,stderr=subprocess.STDOUT,timeout=600)
    else:subprocess.run(command,cwd=ROOT,env=env,check=True,timeout=600)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--node',default=shutil.which('node'))
    parser.add_argument('--electron')
    parser.add_argument('--calibre',default=shutil.which('ebook-convert'))
    args=parser.parse_args()
    electron=args.electron
    if not electron:
        home=ROOT.parent/'node_modules'/'electron';hint=home/'path.txt'
        if hint.exists():electron=str(home/'dist'/hint.read_text(encoding='utf-8').strip())
    calibre=args.calibre
    if not calibre:
        candidates=[Path('/Applications/calibre.app/Contents/MacOS/ebook-convert'),Path(os.environ.get('ProgramFiles','C:/Program Files'))/'Calibre2'/'ebook-convert.exe']
        calibre=next((str(p) for p in candidates if p.is_file()),None)
    if not args.node or not electron or not calibre:parser.error('Set --node, --electron and --calibre to installed developer tools')
    if not (ROOT/'node_modules'/'@lingo-reader'/'mobi-parser').is_dir():parser.error('Run npm ci --ignore-scripts in this evaluation directory first')
    env=dict(os.environ,PYTHONUTF8='1',PYTHONIOENCODING='utf-8',NODE_BIN=str(Path(args.node).resolve()),ELECTRON_BIN=str(Path(electron).resolve()),CALIBRE_BIN=str(Path(calibre).resolve()))
    git=shutil.which('git')
    if not git:parser.error('git is required to fetch pinned parser/sample sources')
    revisions={'foliate-js':('https://github.com/johnfactotum/foliate-js.git',FOLIATE),'jsebook':('https://github.com/daviddrysdale/jsebook.git',JSEBOOK)}
    for name,(url,revision) in revisions.items():
        target=ROOT/name
        if not target.exists():
            if revision:
                run([git,'init',str(target)],env);run([git,'-C',str(target),'remote','add','origin',url],env)
                run([git,'-C',str(target),'fetch','--depth','1','origin',revision],env)
                run([git,'-C',str(target),'checkout','--detach','FETCH_HEAD'],env)
            else:run([git,'clone','--depth','1','--filter=blob:none','--no-checkout',url,str(target)],env)
        if revision:
            actual=subprocess.check_output([git,'-C',str(target),'rev-parse','HEAD'],text=True).strip()
            if actual!=revision:raise RuntimeError('Unexpected '+name+' revision: '+actual)
    metadata={'timestamp_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'node':subprocess.check_output([env['NODE_BIN'],'--version'],text=True).strip(),'calibre':subprocess.check_output([env['CALIBRE_BIN'],'--version'],env=dict(env,CALIBRE_CONFIG_DIRECTORY=str(ROOT/'calibre-config')),text=True).splitlines()[0]}
    electron_env=dict(env,ELECTRON_RUN_AS_NODE='1')
    metadata['electron_versions']=json.loads(subprocess.check_output([env['ELECTRON_BIN'],'-p','JSON.stringify(process.versions)'],env=electron_env,text=True))
    (ROOT/'environment.json').write_text(json.dumps(metadata,indent=2), encoding='utf-8')
    # reset prior transient results so an old successful run cannot mask a new failure
    shutil.rmtree(ROOT/'results',ignore_errors=True)
    for script in ['prepare.py','run.py','extend.py','add-huff.py','run-extended.py']:
        run([sys.executable,str(ROOT/script)],env,script+'.log')
    run([env['ELECTRON_BIN'],str(ROOT/'foliate-main.cjs')],env,'foliate-run.log')
    run([sys.executable,str(ROOT/'electron-node-check.py')],env,'electron-node.log')
    run([sys.executable,str(ROOT/'summarize.py')],env,'summary.log')
    result=json.loads((ROOT/'comparison-summary.json').read_text(encoding='utf-8'))
    selected=result['counts']['foliate']
    if len(result['cases'])!=27 or selected['valid_nonempty']!=24 or selected['controlled_pass']!=15 or selected['upstream_pass']!=7 or selected['negative_pass']!=3:
        raise RuntimeError('Foliate comparison regressed or corpus is incomplete; inspect comparison-summary.json')
    print((ROOT/'summary.log').read_text(encoding='utf-8'))
    print('Finished. See comparison-summary.json and environment.json. Production imports were not changed.')

if __name__=='__main__':main()
