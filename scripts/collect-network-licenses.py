#!/usr/bin/env python3
"""Copy pinned module license notices into the distributable app resources."""
from pathlib import Path
import subprocess, json, os, shutil
root = Path(__file__).resolve().parents[1]
go = os.environ.get('FARREACH_GO') or shutil.which('go') or str(root / '.tools/go/bin/go')
env = dict(os.environ)
env.setdefault('GOCACHE', str(root / '.cache/go-build'))
env.setdefault('GOMODCACHE', str(root / '.cache/go-mod'))
raw = subprocess.check_output([go, 'list', '-deps', '-json', './cmd/farreach-network'], cwd=root/'Networking', env=env, text=True)
decoder=json.JSONDecoder(); modules=[]
while raw.strip():
    item,end=decoder.raw_decode(raw.lstrip()); raw=raw.lstrip()[end:]
    module=item.get('Module')
    if module and not module.get('Main') and module.get('Path') not in {m['Path'] for m in modules}: modules.append(module)
out=root/'Resources/ThirdParty';out.mkdir(parents=True,exist_ok=True)
manifest=[]
for module in modules:
    directory=Path(module['Dir'])
    notices=sorted(p for p in directory.iterdir() if p.is_file() and p.name.upper().startswith(('LICENSE','COPYING','NOTICE')))
    if not notices: raise SystemExit('Missing license notice for '+module['Path'])
    stem=module['Path'].replace('/','_')+'@'+module['Version']
    for path in notices: shutil.copyfile(path,out/(stem+'-'+path.name))
    manifest.append({'module':module['Path'],'version':module['Version'],'notices':[stem+'-'+p.name for p in notices]})
goroot=subprocess.check_output([go,'env','GOROOT'],env=env,text=True).strip()
shutil.copyfile(Path(goroot)/'LICENSE',out/'Go-runtime-LICENSE')
(out/'dependencies.json').write_text(json.dumps(manifest,indent=2)+'\n')
(out/'README.txt').write_text('FarReach is original MIT-licensed source. Its bundled network engine statically links the dependencies listed in dependencies.json. Their license and notice texts are included here, along with the Go runtime license. No Tailscale binary or proprietary code is included. TURN packages are transitive WebRTC dependencies; FarReach disables relay configuration and rejects relay paths. Sparkle.framework provides in-app updates; its license and bundled third-party notices are preserved in Sparkle-LICENSE.\n')
print(f'Collected license notices for {len(modules)} pinned modules and Go runtime.')
