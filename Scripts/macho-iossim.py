#!/usr/bin/env python3
# Relabels a thin arm64 Mach-O built with the old LC_VERSION_MIN_IPHONEOS command as an iOS Simulator binary, in
# place: the 16-byte command is removed and a 24-byte LC_BUILD_VERSION (platform 7, no tools) is appended, using the
# padding after the load commands. (vtool does this by rewriting the file, which broke some binaries' LINKEDIT.)
import struct, sys

LC_VERSION_MIN_IPHONEOS, LC_BUILD_VERSION, LC_SEGMENT_64 = 0x25, 0x32, 0x19

def patch(path):
    data = bytearray(open(path, 'rb').read())
    magic, cputype, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from('<IiiIIIII', data, 0)
    if magic != 0xfeedfacf:
        sys.exit(f'{path}: not a thin 64-bit Mach-O')
    offset, commands, version, first_section = 32, [], None, len(data)
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, offset)
        if cmd == LC_VERSION_MIN_IPHONEOS:
            version = struct.unpack_from('<II', data, offset + 8)
        else:
            commands.append(bytes(data[offset:offset + size]))
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from('<I', data, offset + 64)[0]
            for s in range(nsects):
                sect = offset + 72 + s * 80
                sect_offset = struct.unpack_from('<I', data, sect + 48)[0]
                if sect_offset: first_section = min(first_section, sect_offset)
        offset += size
    if version is None:
        return print(f'{path}: no LC_VERSION_MIN_IPHONEOS, left alone')
    commands.append(struct.pack('<IIIIII', LC_BUILD_VERSION, 24, 7, version[0], version[1], 0))
    blob = b''.join(commands)
    if 32 + len(blob) > first_section:
        sys.exit(f'{path}: no room for LC_BUILD_VERSION')
    data[32:32 + sizeofcmds + 8] = blob + bytes(32 + sizeofcmds + 8 - 32 - len(blob))
    struct.pack_into('<II', data, 16, len(commands), len(blob))
    open(path, 'wb').write(data)
    print(f'{path}: relabelled for the iOS Simulator')

for p in sys.argv[1:]:
    patch(p)
