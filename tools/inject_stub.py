#!/usr/bin/env python3
"""Puts a freshly built forwarder stub into template/template.cia.

The stub is linked like any libctru program (stub/build.sh). Its three load
segments become the ExeFS .code, the exheader code set info is rewritten to
match, and the other ExeFS sections stay where they are: the new code must fit
in the room the old one had. Hashes are left to host/reseal afterwards.

usage: inject_stub.py stub.elf template.cia
"""
import struct
import sys

PAGE = 0x1000


def pad(b, n=PAGE):
    return b + b"\0" * (-len(b) % n)


def load_segments(elf):
    if elf[:4] != b"\x7fELF" or elf[4] != 1 or elf[5] != 1:
        sys.exit("not a 32-bit little-endian ELF")
    phoff, = struct.unpack_from("<I", elf, 0x1C)
    phentsize, phnum = struct.unpack_from("<HH", elf, 0x2A)
    segs = []
    for i in range(phnum):
        p_type, off, vaddr, _, filesz, memsz, flags, _ = struct.unpack_from("<8I", elf, phoff + i * phentsize)
        if p_type == 1 and memsz:
            segs.append((vaddr, elf[off:off + filesz], memsz, flags))
    segs.sort()
    if len(segs) != 3 or [s[3] & 7 for s in segs] != [5, 4, 6]:
        sys.exit("expected text (RX), rodata (R) and data (RW) segments")
    return segs


def main():
    elf = open(sys.argv[1], "rb").read()
    path = sys.argv[2]
    d = bytearray(open(path, "rb").read())

    (ta, text, _, _), (ra, ro, _, _), (da, data, dmem, _) = load_segments(elf)
    if ta != 0x100000 or ra != ta + len(pad(text)) or da != ra + len(pad(ro)):
        sys.exit("segments are not laid out page after page from 0x100000")
    code = pad(text) + pad(ro) + pad(data)
    for marker in (b"FWD0ROM!", b"FWD0CRE!"):
        if code.count(marker) != 1:
            sys.exit("marker %r must appear exactly once" % marker)

    al = lambda v: (v + 63) & ~63
    hdr, = struct.unpack_from("<I", d, 0)
    cert, tik, tmd = struct.unpack_from("<III", d, 8)
    ncch = al(hdr) + al(cert) + al(tik) + al(tmd)
    if d[ncch + 0x100:ncch + 0x104] != b"NCCH":
        sys.exit("no NCCH in the CIA")
    exh = ncch + 0x200
    if d[exh + 0xD] & 1:
        sys.exit("compressed .code is not supported")
    unit = 0x200 << d[ncch + 0x188 + 6]
    exefs = ncch + struct.unpack_from("<I", d, ncch + 0x1A0)[0] * unit

    entries = []
    for i in range(10):
        e = exefs + i * 16
        if d[e]:
            entries.append((d[e:e + 8].rstrip(b"\0"), struct.unpack_from("<II", d, e + 8), e))
    code_entry = [x for x in entries if x[0] == b".code"]
    if not code_entry or code_entry[0][1][0] != 0:
        sys.exit(".code must be the first ExeFS section")
    room = min(off for name, (off, _), _ in entries if off > 0)
    if len(code) > room:
        sys.exit("stub too big: 0x%x bytes, room for 0x%x" % (len(code), room))

    base = exefs + 0x200
    d[base:base + room] = code + b"\0" * (room - len(code))
    struct.pack_into("<I", d, code_entry[0][2] + 12, len(code))

    for slot, (addr, blob) in enumerate(((ta, text), (ra, ro), (da, data))):
        struct.pack_into("<III", d, exh + 0x10 + slot * 0x10, addr, len(pad(blob)) // PAGE, len(blob))
    struct.pack_into("<I", d, exh + 0x3C, dmem - len(data))

    open(path, "wb").write(d)
    print("stub: text 0x%x, ro 0x%x, data 0x%x (+0x%x bss); .code 0x%x of 0x%x"
          % (len(text), len(ro), len(data), dmem - len(data), len(code), room))


if __name__ == "__main__":
    main()
