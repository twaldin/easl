#!/usr/bin/env python3
import ctypes
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import termios
import time
import tty

root = Path(sys.argv[1])
burst = len(sys.argv) > 2 and sys.argv[2] == '--burst'
root.mkdir(parents=True, exist_ok=True)
lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
lib.mach_absolute_time.restype = ctypes.c_uint64
class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]
base = Timebase()
assert lib.mach_timebase_info(ctypes.byref(base)) == 0 and base.numer and base.denom
log = os.open(str(root / 'fixture.jsonl'), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
def record(stage, seq, ticks, **fields):
    os.write(log, (json.dumps(dict(stage=stage, seq=seq, ts_ms=ticks * base.numer / base.denom / 1e6,
                                  ticks=str(ticks), pid=os.getpid(), **fields)) + '\n').encode())
original = termios.tcgetattr(0)
tty.setraw(0)
if burst:
    modes = termios.tcgetattr(0)
    modes[1] |= termios.OPOST | termios.ONLCR
    termios.tcsetattr(0, termios.TCSANOW, modes)
seq = 0
try:
    os.write(1, b'\x1b[?25l\x1b[0m\x1b[40m\x1b[2J\x1b[HECHO READY\x1b]777;easl-echo;ready\x07')
    modes = termios.tcgetattr(0)
    (root / 'fixture-ready.json').write_text(json.dumps({'pid': os.getpid(), 'modes': modes[:6], 'control': [value.hex() if isinstance(value, bytes) else value for value in modes[6]]}) + '\n')
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline and not (root / 'stop-fixture').exists():
        if not select.select([0], [], [], .01)[0]:
            continue
        data = os.read(0, 4096)
        ticks = lib.mach_absolute_time()
        if not data:
            break
        for byte in data:
            seq += 1
            record('fixture.received', seq, ticks, ascii=byte)
            if byte != 97 or seq > 100:
                record('fixture.error', seq, ticks, error='expected exactly 100 ASCII a keys')
                raise SystemExit(1)
            if burst:
                assert seq == 1
                started = lib.mach_absolute_time()
                subprocess.run(['/usr/bin/seq', '1', '20000'], stdout=1, check=True)
                os.write(1, b'\x1b[2J\x1b[H')
                record('fixture.burst', seq, started, bytes=128894)
            row, column = (seq - 1) // 10 + 3, (seq - 1) % 10 * 2 + 3
            output = ('\x1b[%d;%dH\x1b[48;2;20;40;160m\x1b[38;2;255;255;255ma\x1b[0m\x1b]777;easl-echo;%d\x07' % (row, column, seq)).encode()
            before = lib.mach_absolute_time()
            sent = os.write(1, output)
            after = lib.mach_absolute_time()
            record('fixture.output', seq, before, returned_ms=after * base.numer / base.denom / 1e6, bytes=sent)
            assert sent == len(output)
    record('fixture.stopped', seq, lib.mach_absolute_time(), complete=seq == 100)
finally:
    termios.tcsetattr(0, termios.TCSANOW, original)
    os.close(log)
