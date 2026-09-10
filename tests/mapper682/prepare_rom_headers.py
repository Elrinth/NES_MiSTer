"""Create small header fixtures from the user's test ROMs; no ROM payloads copied."""
import hashlib
import json
from pathlib import Path
import sys

source=Path(sys.argv[1])
output=Path(__file__).resolve().parent
entries=[]
raw=[]
paths=sorted(source.glob('*.nes'))
assert len(paths)==12, 'Expected the twelve Rainbow compatibility variants'
if len(sys.argv)>2:
    paths.append(Path(sys.argv[2]))
for p in paths:
    b=p.read_bytes()
    h=b[:16]
    assert h[:4]==b'NES\x1a' and h[7]&12==8,p
    mapper=(h[6]>>4)|(h[7]&240)|((h[8]&15)<<8)
    assert mapper==682,p
    assert h[9]&15!=15 and h[9]>>4!=15,'exponent header requires extra fixture'
    prg=(h[4]|((h[9]&15)<<8))*16384
    chr=(h[5]|((h[9]>>4)<<8))*8192
    assert len(b)==16+prg+chr,p
    entries.append(dict(file=p.name,sha256=hashlib.sha256(b).hexdigest(),
        prg_bytes=prg,chr_bytes=chr,prg_ram_bytes=64<<(h[10]&15),
        chr_ram_bytes=(64<<(h[11]&15)) if h[11]&15 else 0,header=h.hex()))
    raw.extend(h)
assert len(entries)==13, 'Also supply the current SotN ROM as the second input'
(output/'rom_headers.hex').write_text('\n'.join(f'{v:02x}' for v in raw)+'\n')
(output/'rom_inventory.json').write_text(json.dumps(entries,indent=2)+'\n')
print(f'Prepared {len(entries)} real NES 2.0 headers (12 tests + SotN); PRG/CHR up to 8MiB each.')
