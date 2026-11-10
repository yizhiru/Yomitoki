const {app,BrowserWindow,ipcMain,session}=require('electron');
const fs=require('node:fs/promises');const path=require('node:path');
const root=__dirname;
app.setPath('userData',path.join(root,'electron-profile'));
app.setPath('crashDumps',path.join(root,'electron-crash-dumps'));
app.commandLine.appendSwitch('disable-gpu');
const watchdog=setTimeout(()=>{console.error('Electron evaluation exceeded 120 seconds');app.exit(2);},120000);
app.whenReady().then(async()=>{
  app.dock?.hide();
  const cases=JSON.parse(await fs.readFile(path.join(root,'manifest-final.json'),'utf8'));
  ipcMain.handle('eval:cases',()=>cases.map(({id,file,kind})=>({id,file,kind})));
  ipcMain.handle('eval:bytes',async(_event,id)=>{
    const entry=cases.find(x=>x.id===id);if(!entry)throw new Error('Unknown sample');
    return new Uint8Array(await fs.readFile(path.join(root,'corpus',entry.file)));
  });
  ipcMain.handle('eval:result',async(_event,id,result)=>{
    if(!cases.some(x=>x.id===id)) throw new Error('Unknown sample');
    await fs.writeFile(path.join(root,'results',id+'.foliate.json'),JSON.stringify(result));
    console.log(JSON.stringify({id,ok:result.ok,characters:result.text?.length,error:result.error,milliseconds:result.milliseconds}));
  });
  ipcMain.on('eval:done',()=>{clearTimeout(watchdog);app.quit();});
  session.defaultSession.webRequest.onBeforeRequest({urls:['http://*/*','https://*/*']},(_details,callback)=>callback({cancel:true}));
  const win=new BrowserWindow({show:false,webPreferences:{preload:path.join(root,'foliate-preload.cjs'),contextIsolation:true,nodeIntegration:false,sandbox:true}});
  win.webContents.on('preload-error',(_e,_p,error)=>console.error(error.message));
  win.webContents.on('console-message',event=>{if(event.level==='error') console.error(event.message);});
  await win.loadFile(path.join(root,'foliate.html'));
}).catch(error=>{console.error(error);app.exit(1);});
