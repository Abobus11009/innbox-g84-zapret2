#!/usr/bin/env python3
from pathlib import Path
r=Path(__file__).resolve().parents[1]
p=r/'g84-zapret2.sh';s=p.read_text();a=s.index('# BEGIN EMBEDDED UNINSTALL');b=s.index('# END EMBEDDED UNINSTALL',a)+len('# END EMBEDDED UNINSTALL')
body="""# BEGIN EMBEDDED UNINSTALL
upload_uninstall_tools() {
  remote 'test ! -e /var/tmp/zapret2-uninstall && mkdir /var/tmp/zapret2-uninstall && chmod 700 /var/tmp/zapret2-uninstall && /bin/ash -s' <<'G84_EMBEDDED_TOOLS'
"""
for filename in ['lib.sh','install-transaction.sh']:
 marker='G84_SOURCE_'+filename.replace('.','_').replace('-','_').upper()
 source=(r/'router'/filename).read_text()
 assert marker not in source
 body+=f"cat > /var/tmp/zapret2-uninstall/{filename} <<'{marker}' || exit 1\n"+source+'\n'+marker+'\n'
body+="G84_EMBEDDED_TOOLS\n}\n# END EMBEDDED UNINSTALL"
p.write_text(s[:a]+body+s[b:])
