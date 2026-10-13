#!/usr/bin/env python3
"""Read-only router CPU/queue samples around a bounded client download."""
import argparse, json, pathlib, subprocess, tempfile, time, urllib.parse
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--host',default='superadmin@192.168.1.1')
p.add_argument('--url',required=True,help='Public test file served via the router; no credentials in URL')
p.add_argument('--seconds',type=int,default=20)
p.add_argument('--protocol',choices=['http1','http3'],default='http1')
p.add_argument('--label',default='active')
a=p.parse_args()
if not 1<=a.seconds<=60:p.error('--seconds must be between 1 and 60')
u=urllib.parse.urlsplit(a.url)
if u.scheme not in ['http','https'] or u.username or u.password:p.error('use a public HTTP(S) URL without credentials')
sample='''/bin/ash -c 'cat /proc/stat; echo NFQ_PROCESS; p=`cat /var/tmp/zapret2-nfqws.pid 2>/dev/null`; if [ -n "$p" ]; then cat /proc/$p/stat; fi; echo NFQUEUE; cat /proc/net/netfilter/nfnetlink_queue; echo COUNTERS; iptables -t mangle -L Z2OUT -n -v -x' '''.strip()
def parse(raw):
    lines=raw.splitlines(); cpu=next(l for l in lines if l.startswith('cpu ')).split()
    ticks=list(map(int,cpu[1:9])); total=sum(ticks); idle=ticks[3]+ticks[4]
    proc=lines[lines.index('NFQ_PROCESS')+1]
    if proc=='NFQUEUE':pid=None; process_ticks=0
    else:
        pid=int(proc.split()[0]); fields=proc[proc.rindex(')')+2:].split()
        process_ticks=int(fields[11])+int(fields[12])
    queues=[]
    for line in lines[lines.index('NFQUEUE')+1:lines.index('COUNTERS')]:
        f=line.split()
        if len(f)>=8:queues.append(dict(queue=int(f[0]),owner=int(f[1]),kernel_drops=int(f[5]),user_drops=int(f[6]),sequence=int(f[7])))
    return dict(total=total,idle=idle,cores=sum(l.startswith('cpu') and len(l)>3 and l[3].isdigit() for l in lines),pid=pid,process_ticks=process_ticks,queues=queues,counters=lines[lines.index('COUNTERS')+1:])
with tempfile.TemporaryDirectory(prefix='g84-benchmark-') as d:
    options=['-o','KexAlgorithms=+diffie-hellman-group1-sha1','-o','HostKeyAlgorithms=+ssh-rsa','-o','ConnectTimeout=8','-o','ControlPath='+str(pathlib.Path(d)/'ssh')]
    subprocess.run(['ssh',*options,'-MNf',a.host],check=True)
    try:
        def read():return parse(subprocess.check_output(['ssh',*options,a.host,sample],text=True))
        before=read();start=time.monotonic()
        result=subprocess.run(['curl','--fail','--http1.1' if a.protocol=='http1' else '--http3-only','--silent','--show-error','--max-time',str(a.seconds),'--range','0-33554431','--max-filesize','33554432','--output','/dev/null','--write-out','%{json}',a.url],capture_output=True,text=True)
        elapsed=time.monotonic()-start;after=read()
        delta=after['total']-before['total']
        transfer=json.loads(result.stdout) if result.stdout else {}
        valid=result.returncode==0 and transfer.get('http_code') in [200,206] and transfer.get('size_download',0)>=1048576 and delta>0 and (a.protocol!='http3' or str(transfer.get('http_version')) in ['3','3.0'])
        stable=before['pid']==after['pid']
        report=dict(measurement_valid=valid,http_status=transfer.get('http_code'),http_version=transfer.get('http_version'),label=a.label,protocol=a.protocol,server=u.hostname,elapsed_seconds=round(elapsed,3),curl_exit=result.returncode,download_bytes=transfer.get('size_download'),bytes_per_second=transfer.get('speed_download'),cpu_busy_percent=round(100*(1-(after['idle']-before['idle'])/delta),2) if delta>0 else None,nfq_cpu_percent_one_core=round(100*before['cores']*(after['process_ticks']-before['process_ticks'])/delta,2) if delta>0 and stable else None,process_stable=stable,before=before,after=after)
        print(json.dumps(report,indent=2))
        if result.returncode:raise SystemExit(result.returncode)
        if not valid:raise SystemExit(65)
    finally:subprocess.run(['ssh',*options,'-O','exit',a.host],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
