#!/usr/bin/env python3
"""Portable, deterministic ustar archive accepted by BusyBox 1.00."""
import gzip, pathlib, sys, tarfile
stage, output = map(pathlib.Path, sys.argv[1:])
with output.open('wb') as raw, gzip.GzipFile(filename='',mode='wb',fileobj=raw,mtime=0,compresslevel=9) as gz:
    with tarfile.open(fileobj=gz,mode='w',format=tarfile.USTAR_FORMAT) as archive:
        for path in [stage/'zapret2', *sorted((stage/'zapret2').iterdir())]:
            info=archive.gettarinfo(str(path),arcname=str(path.relative_to(stage)))
            info.uid=info.gid=0;info.uname=info.gname='';info.mtime=1767225600
            info.mode=0o755 if path.is_dir() or path.suffix=='.sh' or path.name in ['nfqws2','g84-lock'] else 0o644
            if path.is_file():
                with path.open('rb') as content:archive.addfile(info,content)
            else:archive.addfile(info)
