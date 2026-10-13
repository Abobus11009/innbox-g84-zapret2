#!/usr/bin/env python3
"""Build a self-contained local setup application (no external shell tools)."""
import os,pathlib,platform,subprocess,sys,shutil,tarfile
root=pathlib.Path(__file__).resolve().parents[1]
name='g84-setup-'+{'Windows':'windows','Darwin':'macos','Linux':'linux'}[platform.system()]+'-'+platform.machine().lower().replace('amd64','x86_64')
args=[sys.executable,'-m','PyInstaller','--noconfirm','--clean','--onefile','--name',name,'--paths',str(root/'desktop'),'--distpath',str(root/'.build/desktop/dist'),'--workpath',str(root/'.build/desktop/work'),'--specpath',str(root/'.build/desktop')]
for file,destination in [('manifest.env','.'),('g84-zapret2-payload.tar.gz','.'),('desktop/ui.html','desktop')]:args+=['--add-data',str(root/file)+os.pathsep+destination]
if platform.system() in ['Windows','Darwin']:args+=['--windowed']
args+=[str(root/'g84-setup.py')]
subprocess.run(args,cwd=root,check=True)
exe=root/'.build/desktop/dist'/(name+('.exe' if os.name=='nt' else ''))
if platform.system()=='Darwin':exe=root/'.build/desktop/dist'/(name+'.app')/'Contents/MacOS'/name
env=dict(os.environ,G84_DATA_DIR=str(root/'.build/desktop/smoke-state'))
subprocess.run([str(exe),'--self-test'],env=env,check=True,timeout=60)
artifacts=root/'.build/desktop/artifacts';artifacts.mkdir(exist_ok=True)
if platform.system()=='Darwin':
    shutil.make_archive(str(artifacts/name),'zip',root/'.build/desktop/dist',name+'.app')
elif platform.system()=='Linux':
    with tarfile.open(artifacts/(name+'.tar.gz'),'w:gz') as archive:archive.add(exe,arcname=name)
else:shutil.copy2(exe,artifacts/exe.name)
print('Packaged application:',artifacts)
