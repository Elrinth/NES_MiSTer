"""Extract original bank tables/signatures: python prepare_bank_signatures.py ROM"""
from pathlib import Path
import hashlib
import sys

p = Path(__file__).resolve().parent
raw = Path(sys.argv[1]).read_bytes()
assert hashlib.sha256(raw).hexdigest() in {
    '3dbea104310cc758c3e15786c983c65c575bff7b854844ba2d9c168dd6de8ef6',
    '055b52b46fc8fa24abf710ba579b248c15f290cfdf75993dba36c009346ee86f',
}, 'Unsupported test ROM revision'
r = raw[16:]
vectors = []

def op(kind, address, value):
    vectors.append(f'{kind:x}{address:04x}{value:02x}')

for start, is_chr in [(0x793, False), (0x85a, False), (0xb8e, True), (0xc34, True)]:
    a = start
    while r[a] != 255:
        row = r[a:a+11]
        mode = row[0]
        count = int.from_bytes(row[1:3], 'little')
        high = int.from_bytes(row[3:5], 'little')
        low = int.from_bytes(row[5:7], 'little')
        address = int.from_bytes(row[7:9], 'little')
        op(0, 0x4120 if is_chr else 0x4100, mode)
        for bank in range(count):
            op(0, low, bank & 255)
            op(0, high, bank >> 8)
            op(2 if is_chr else 1, address, bank >> 8)
            op(2 if is_chr else 1, address+1, bank & 255)
            op(2 if is_chr else 1, (address & 0xff00)+10, 0x4f)
        a += 11
assert len(vectors) == 1893172
p.joinpath('bank_vectors.hex').write_text('\n'.join(vectors)+'\n')
for name, offset, step in [('prg', 0, 4096), ('chr', 8388608, 512)]:
    data = b''.join(r[i:i+11] for i in range(offset, offset+8388608, step))
    p.joinpath(name+'_signatures.hex').write_text('\n'.join(f'{b:02x}' for b in data)+'\n')
for name, data in [('prg_first32k', r[:32768]), ('prg_test_code', r[0x6c6:0x714]), ('prg_test_table', r[0x793:0x859]+r[0x85a:0x87b])]:
    p.joinpath(name+'.hex').write_text('\n'.join(f'{b:02x}' for b in data)+'\n')
print('Prepared 1,893,172 transactions and original 6502 PRG test routine.')
