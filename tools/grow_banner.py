#!/usr/bin/env python3
"""Grows the banner section of romfs/template.cia, so a longer banner sound fits.

The banner is the only ExeFS section allowed to change size between builds,
so the template reserves room for it. 256 KB held the artwork and about one
second of audio; the PS1 boot jingle alone is 375 KB (3 s, stereo, PCM16).

Every section after the banner moves down, and every size that covers them
grows: ExeFS, NCCH, the CIA content size and the TMD content chunk. Hashes are
recomputed afterwards by host/reseal (cia_reseal), the same code the apps use.

    python3 tools/grow_banner.py romfs/template.cia 0x80000
"""
import struct
import sys

def align(v, a):
    return (v + a - 1) & ~(a - 1)

SIG = {0x10000: 0x23C, 0x10001: 0x13C, 0x10002: 0x7C,
       0x10003: 0x23C, 0x10004: 0x13C, 0x10005: 0x7C}

def main(path, new_size):
    d = bytearray(open(path, 'rb').read())
    hdr, = struct.unpack_from('<I', d, 0)
    cert, tik, tmd, meta = struct.unpack_from('<IIII', d, 8)
    content_size, = struct.unpack_from('<Q', d, 0x18)
    tmd_off = align(hdr, 64) + align(cert, 64) + align(tik, 64)
    content = tmd_off + align(tmd, 64)
    tmd_body = tmd_off + 4 + SIG[struct.unpack_from('>I', d, tmd_off)[0]]

    ncch = content
    assert d[ncch + 0x100:ncch + 0x104] == b'NCCH'
    unit = 0x200 << d[ncch + 0x188 + 6]
    exefs = ncch + struct.unpack_from('<I', d, ncch + 0x1A0)[0] * unit
    romfs_size = struct.unpack_from('<I', d, ncch + 0x1B4)[0]
    assert romfs_size == 0, 'a RomFS after the ExeFS would have to move too'

    entries = []
    for i in range(10):
        name = bytes(d[exefs + i * 16:exefs + i * 16 + 8]).rstrip(b'\0')
        if name:
            off, size = struct.unpack_from('<II', d, exefs + i * 16 + 8)
            entries.append((i, name, off, size))
    banner = [e for e in entries if e[1] == b'banner'][0]
    grow = new_size - banner[3]
    assert grow > 0 and grow % unit == 0, 'new size must be larger, in whole media units'
    for i, name, off, size in entries:
        assert name == b'banner' or off < banner[2] or off >= banner[2] + banner[3]

    insert_at = exefs + 0x200 + banner[2] + banner[3]
    d[insert_at:insert_at] = bytes(grow)

    for i, name, off, size in entries:
        if name == b'banner':
            struct.pack_into('<I', d, exefs + i * 16 + 12, new_size)
        elif off > banner[2]:
            struct.pack_into('<I', d, exefs + i * 16 + 8, off + grow)

    for field in (0x104, 0x1A4):           # NCCH size, ExeFS size, in media units
        v, = struct.unpack_from('<I', d, ncch + field)
        struct.pack_into('<I', d, ncch + field, v + grow // unit)

    struct.pack_into('<Q', d, 0x18, content_size + grow)
    count, = struct.unpack_from('>H', d, tmd_body + 0x9E)
    assert count == 1
    chunk = tmd_body + 0xC4 + 64 * 0x24
    csize, = struct.unpack_from('>Q', d, chunk + 8)
    struct.pack_into('>Q', d, chunk + 8, csize + grow)

    open(path, 'wb').write(d)
    print('banner %d -> %d bytes, CIA %d bytes' % (banner[3], new_size, len(d)))

if __name__ == '__main__':
    main(sys.argv[1], int(sys.argv[2], 0))
