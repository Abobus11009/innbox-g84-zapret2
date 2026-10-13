#!/usr/bin/env python3
"""Read-only HTTP/3 measurement; never detaches rules or changes services."""
import argparse,getpass,json,pathlib,sys,time,urllib.parse
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'desktop'))
from g84_setup.access import RouterSSH,local_address
from curl_cffi import CurlHttpVersion,requests
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--host',default='192.168.1.1');p.add_argument('--url',required=True);p.add_argument('--samples',type=int,default=3);p.add_argument('--state-dir',required=True)
a=p.parse_args();host=local_address(a.host);url=urllib.parse.urlsplit(a.url)
if url.scheme!='https' or url.username or url.password or not 1<=a.samples<=10:p.error('use public HTTPS URL and 1..10 samples')
ssh=RouterSSH(host,getpass.getpass('superadmin password: '),pathlib.Path(a.state_dir))
def sample():
 _,out,_=ssh.run('cat /proc/stat; echo QUEUE; cat /proc/net/netfilter/nfnetlink_queue')
 lines=out.decode().splitlines();ticks=list(map(int,lines[0].split()[1:9]));return dict(total=sum(ticks),idle=ticks[3]+ticks[4],queue=lines[lines.index('QUEUE')+1:])
reports=[]
try:
 for _ in range(a.samples):
  before=sample();start=time.monotonic()
  with requests.Session(trust_env=False) as session:
   with session.get(a.url,http_version='v3only',timeout=30,stream=True) as r:
    count=0
    for block in r.iter_content():
     count+=len(block)
     if count>33554432:raise RuntimeError('Maximum sample size is 32 MiB')
    http_status=r.status_code;http_version=r.http_version
  elapsed=time.monotonic()-start;after=sample();delta=after['total']-before['total']
  valid=http_status in [200,206] and count>=1048576 and http_version==CurlHttpVersion.V3 and delta>0
  reports.append(dict(valid=valid,server=url.hostname,http_status=http_status,http_version=int(http_version),bytes=count,seconds=round(elapsed,3),mbps=round(count*8/elapsed/1e6,2),cpu_busy_percent=round(100*(1-(after['idle']-before['idle'])/delta),2) if delta>0 else None,before=before,after=after))
 print(json.dumps(reports,indent=2))
 if not all(r['valid'] for r in reports):raise SystemExit(65)
finally:ssh.close()
