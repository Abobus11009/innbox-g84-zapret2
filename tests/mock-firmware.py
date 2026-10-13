#!/usr/bin/env python3
"""Isolated firmware CLI. No host processes or network configuration are touched."""
import json, os, pathlib, subprocess, sys, re

home = pathlib.Path(os.environ['MOCK_HOME'])
store = home / 'state.json'
data = json.loads(store.read_text())
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
base = pathlib.Path(os.environ['Z2_BASE'])
proc = pathlib.Path(os.environ['Z2_PROC'])
tmp = pathlib.Path(os.environ['Z2_TMP'])
version = (base/'VERSION').read_text().strip() if (base/'VERSION').exists() else ''

def save(): store.write_text(json.dumps(data))
def fail(point):
    if os.environ.get('FAIL_AT') == point and point not in data['failures']:
        data['failures'].append(point); save(); return True
    return False

if tool in ('cp','chmod','mv'):
    point = None
    if tool == 'cp' and args[-1].rstrip('/').endswith('.new'): point='copy'
    if tool == 'cp' and args[-2].endswith('/zapret2/hosts.txt') and args[-1].endswith('.new/hosts.txt'): point='preserve'
    if tool == 'chmod' and any('.new/' in a for a in args): point='chmod'
    if tool == 'mv' and args[-1].endswith('.old'): point='rename-old'
    if tool == 'mv' and args[0].endswith('.new'): point='rename-new'
    if point and fail(point): sys.exit(1)
    os.execv('/bin/'+tool,['/bin/'+tool]+args)
elif tool == 'sleep':
    sys.exit(subprocess.call(['/bin/sleep','0.01']))
elif tool == 'csmconf':
    action,key=args[:2]
    parts=key.strip('/').split('/')
    if action == '-g':
        if os.environ.get('FAIL_AT')=='slot-read' and parts[-1]=='name': sys.exit(1)
        if os.environ.get('FAIL_AT')=='slot-path-read' and parts[-1]=='path': sys.exit(1)
        if os.environ.get('FAIL_AT')=='slot-readback' and data.get('slot_deleted'): sys.exit(1)
        if parts[0] not in data['slots']: sys.exit(0) # matches firmware empty vacant name
        if parts[-1] not in data['slots'][parts[0]]: sys.exit(1)
        print(data['slots'][parts[0]][parts[-1]]); sys.exit(0)
    if action == '-s':
        if parts[-1]=='path' and fail('register'): sys.exit(1)
        if os.environ.get('FAIL_AT')=='rollback' and parts[-1]=='argument': sys.exit(1)
        data['slots'].setdefault(parts[0],{})[parts[-1]]=args[2]; save(); sys.exit(0)
    if action == '-d':
        if os.environ.get('FAIL_AT')=='slot-delete': sys.exit(1)
        data['slot_deleted']=True
        if len(parts)==1: data['slots'].pop(parts[0],None)
        else: data['slots'].get(parts[0],{}).pop(parts[-1],None)
        save(); sys.exit(0)
elif tool == 'csmctl':
    sys.exit(1 if fail('save') else 0)
elif tool == 'appmgrcmd':
    action,name=args[:2]
    index={'zapret2':90001,'zapret2-rules':90002}[name]
    pf=tmp/('zapret2-nfqws.pid' if name=='zapret2' else 'zapret2-watch.pid')
    cmd=proc/str(index)/'cmdline'
    if action=='stop':
        cmd.unlink(missing_ok=True); pf.unlink(missing_ok=True)
        data['active'][name]=False
        if name=='zapret2': (proc/'net/netfilter/nfnetlink_queue').write_text('')
        save(); sys.exit(1) # nominal IPC success, nonzero exit on stock firmware
    if action=='add':
        if version!='0.3.0' and name=='zapret2' and fail('start'): sys.exit(1)
        # Simulate run.sh's rules startup before the handler binds NFQUEUE.
        if name=='zapret2':
            result=subprocess.run(['/bin/sh',str(base/'add-rules.sh')])
            if result.returncode: sys.exit(result.returncode)
            data=json.loads(store.read_text())
        cmd.parent.mkdir(exist_ok=True)
        path=str(base/('nfqws2' if name=='zapret2' else 'watch-rules.sh'))
        cmd.write_bytes((path+'\0' if name=='zapret2' else '/bin/ash\0'+path+'\0start\0').encode())
        pf.write_text(str(index))
        if name=='zapret2':
            owner=12345 if version!='0.3.0' and fail('verify') else index
            configured=re.findall(r'^QNUM=([0-9]+)$',(base/'config').read_text(),re.M)
            qnum=configured[-1] if configured else '200'
            (proc/'net/netfilter/nfnetlink_queue').write_text(f'{qnum} {owner} 0 2 65531 0 0 5 1\n')
        data['active'][name]=True
        data['starts'].append([version,name,args[3],args[4]])
        save(); sys.exit(1)
elif tool in ('iptables','ip6tables'):
    if args==['--version']: print(tool+' v1.4.21');sys.exit(0)
    if args[:2]!=['-t','mangle']: sys.exit(2)
    action,chain=args[2:4]; rule=args[4:]
    table=data['tables'][tool]
    if action=='-S':
        if chain not in table: sys.exit(1)
        print('-N '+chain)
        for r in table[chain]:print('-A '+chain+' '+' '.join(r))
    elif action=='-N':
        if chain in table:sys.exit(1)
        table[chain]=[];save()
    elif action=='-C':sys.exit(0 if rule in table.get(chain,[]) else 1)
    elif action in ('-A','-I'):
        if chain not in table:sys.exit(1)
        table[chain].append(rule);save()
    elif action=='-D':
        if rule not in table.get(chain,[]):sys.exit(1)
        table[chain].remove(rule);save()
    elif action=='-F':table[chain]=[];save()
    elif action=='-X':table.pop(chain,None);save()
    else:sys.exit(2)
    sys.exit(0)
else:
    raise RuntimeError('unknown mock command '+tool)
