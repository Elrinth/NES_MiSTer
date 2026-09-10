from pathlib import Path
import argparse, hashlib
from py65.devices.mpu6502 import MPU
from py65.assembler import Assembler
r=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description="Create the instrumented vector diagnostic (requires py65).")
parser.add_argument("rom",type=Path)
src=parser.parse_args().rom
b=bytearray(src.read_bytes());assert hashlib.sha256(b).hexdigest()=='055b52b46fc8fa24abf710ba579b248c15f290cfdf75993dba36c009346ee86f'
a=Assembler(MPU());pc=0xaf48;start=pc
entries={}
def emit(*lines):
 global pc
 for line in lines:
  v=a.assemble(line,pc);off=16+pc-32768
  assert all(x==0 for x in b[off:off+len(v)])
  b[off:off+len(v)]=bytes(v);pc+=len(v)
def patch(addr,lines):
 for line in lines:
  v=a.assemble(line,addr);b[16+addr-32768:16+addr-32768+len(v)]=bytes(v);addr+=len(v)
entries['arm']=pc
emit('LDA #$01','STA $07FF','LDA #$AA','STA $B9','RTS')
entries['irq']=pc
emit('PHA','LDA #$02','STA $07FF','STA $415B','LDA #$03','STA $07FF','LDA $B9','EOR #$FF','STA $B9','INC $1A','PLA','RTI')
entries['returned']=pc
emit('LDA #$04','STA $07FF','LDA $B9','CMP #$55','RTS')
entries['nmi']=pc
emit('PHA','LDA $07FF')
guard1=pc;emit('BEQ $0000')
emit('LDA $1D','AND #$18')
guard2=pc;emit('BEQ $0000')
emit('LDA #$20','STA $2006','LDA #$E0','STA $2006','LDA #$44','STA $2007','LDA #$3A','STA $2007','LDA $07FF','AND #$07','ORA #$30','STA $2007','LDA #$20','STA $2007','LDA #$49','STA $2007','LDA #$3A','STA $2007','LDA $4161','ROL A','ROL A','ROL A','AND #$03','ORA #$30','STA $2007')
tail=pc;emit('PLA','JMP $FEFE')
patch(guard1,[f'BEQ ${tail:04X}'])
patch(guard2,[f'BEQ ${tail:04X}'])
assert pc<=0xb005,(hex(pc),hex(start))
patch(0xcf65,[f"JSR ${entries['arm']:04X}",'NOP'])
patch(0xcfb6,[f"JMP ${entries['irq']:04X}"])
patch(0xcf96,[f"JSR ${entries['returned']:04X}",'NOP'])
b[16+0x7ffa:16+0x7ffc]=entries['nmi'].to_bytes(2,'little')
name='rnbw-mapper-test-8192-vector-watchdog-v2.nes';dst=r/'releases'/name;dst.write_bytes(b)
(r/'releases'/name).with_suffix('.txt').write_text('Diagnostic copy of the ROM+RAM test ROM. Select Vector Redirect.\nD:1 = IRQ test entered; D:2 = handler entered; D:3 = IRQ acknowledged; D:4 = mainline returned.\nI:0..3 = pending interrupt flags (bit0 CPU, bit1 scanline).\nNMI writes markers only after the IRQ test starts and while rendering is enabled; menu VRAM uploads are left alone. Timer reload remains 20 CPU cycles.\nInstrumentation lengthens the handler and adds calls before/after the timed section.\nThis is a diagnostic, not a replacement/fix for the original test ROM.\n')
print(dst,hex(pc),entries)
