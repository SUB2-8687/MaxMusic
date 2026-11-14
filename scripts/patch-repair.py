#!/usr/bin/env python3
"""Inject a standalone repair into YouTube Music and its stock WidgetKit extension.

Preserves original entitlements, then ad-hoc signs changed binaries. Feather
must re-sign the complete output with a common App Group before installation.
"""
import argparse
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import zipfile

INSTALL_NAME = '@executable_path/Frameworks/YTMUPlaybackRepair.dylib'
EXT_INSTALL_NAME = '@executable_path/../../Frameworks/YTMUPlaybackRepair.dylib'


def inject(data, name):
    data = bytearray(data)
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xfeedfacf:
        raise ValueError('Expected thin 64-bit Mach-O')
    count, size = struct.unpack_from('<II', data, 16)
    end = 32 + size
    if end > len(data):
        raise ValueError('Invalid load command size')
    pos, first = 32, len(data)
    for _ in range(count):
        if pos + 8 > end:
            raise ValueError('Truncated load command')
        cmd, length = struct.unpack_from('<II', data, pos)
        if length < 8 or length > end - pos:
            raise ValueError('Invalid load command')
        if cmd in (0x21, 0x2c):
            if length < 20 or struct.unpack_from('<I', data, pos + 16)[0] != 0:
                raise ValueError('Encrypted or malformed executable; supply a decrypted IPA')
        if cmd in (0xc, 0x80000018, 0x8000001f) and length >= 24:
            offset = struct.unpack_from('<I', data, pos + 8)[0]
            if bytes(data[pos + offset:pos + length]).split(b'\0')[0] == name.encode():
                return bytes(data)
        if cmd == 0x19:
            if length < 72:
                raise ValueError('Truncated segment')
            sections = struct.unpack_from('<I', data, pos + 64)[0]
            if 72 + sections * 80 > length:
                raise ValueError('Truncated sections')
            for i in range(sections):
                offset = struct.unpack_from('<I', data, pos + 72 + i * 80 + 48)[0]
                if offset:
                    first = min(first, offset)
        pos += length
    if pos != end:
        raise ValueError('Load command count disagrees with size')
    raw = name.encode() + b'\0'
    length = (24 + len(raw) + 7) & ~7
    if end + length > first or any(data[end:end + length]):
        raise ValueError('Insufficient Mach-O header padding')
    # Required load: a missing repair must not silently yield a "fixed" IPA.
    command = struct.pack('<IIIIII', 0xc, length, 24, 0, 0x10000, 0x10000) + raw
    data[end:end + length] = command.ljust(length, b'\0')
    struct.pack_into('<II', data, 16, count + 1, size + length)
    return bytes(data)


def patch(source, output, dylib, ldid):
    source, output = Path(source), Path(output)
    if source.resolve() == output.resolve():
        raise ValueError('Use a separate output to preserve the original IPA')
    if not dylib.is_file():
        raise ValueError('Repair dylib not found')
    with zipfile.ZipFile(source) as archive, tempfile.TemporaryDirectory() as work:
        names = archive.namelist()
        hosts = [n for n in names if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/Info.plist')]
        if len(hosts) != 1:
            raise ValueError('Expected one app')
        root = hosts[0].removesuffix('Info.plist')
        info = plistlib.loads(archive.read(hosts[0]))
        if info.get('CFBundleExecutable') != 'YouTubeMusic':
            raise ValueError('Expected YouTube Music')
        targets = {root + 'YouTubeMusic': INSTALL_NAME}
        for name in names:
            if not name.startswith(root + 'PlugIns/') or not name.endswith('.appex/Info.plist'):
                continue
            ext = plistlib.loads(archive.read(name))
            if ext.get('NSExtension', {}).get('NSExtensionPointIdentifier') == 'com.apple.widgetkit-extension':
                targets[name.removesuffix('Info.plist') + ext['CFBundleExecutable']] = EXT_INSTALL_NAME
        if len(targets) < 2:
            raise ValueError('Stock WidgetKit extension missing')
        changes = {}
        for n, install in targets.items():
            binary = Path(work) / 'binary'
            binary.write_bytes(archive.read(n))
            entitlements = subprocess.check_output([ldid, '-e', str(binary)])
            if not entitlements.strip():
                raise ValueError('Cannot preserve entitlements: ' + n)
            original = plistlib.loads(entitlements)
            ents = Path(work) / 'entitlements.plist'
            ents.write_bytes(entitlements)
            binary.write_bytes(inject(binary.read_bytes(), install))
            subprocess.run([ldid, '-S' + str(ents), str(binary)], check=True)
            after = plistlib.loads(subprocess.check_output([ldid, '-e', str(binary)]))
            if after != original:
                raise ValueError('Entitlements changed unexpectedly: ' + n)
            changes[n] = binary.read_bytes()
        repair = root + 'Frameworks/YTMUPlaybackRepair.dylib'
        if repair in names:
            raise ValueError('Repair already packaged; use the original input')
        output.parent.mkdir(parents=True, exist_ok=True)
        fd, staging = tempfile.mkstemp(prefix='.ytmu-repair-', suffix='.ipa', dir=output.parent)
        os.close(fd)
        try:
            with zipfile.ZipFile(staging, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as result:
                for entry in archive.infolist():
                    result.writestr(entry, changes.get(entry.filename) if entry.filename in changes else archive.read(entry.filename))
                entry = zipfile.ZipInfo(repair)
                entry.external_attr = 0o100755 << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                result.writestr(entry, dylib.read_bytes())
            with zipfile.ZipFile(staging) as result:
                if result.testzip():
                    raise ValueError('Output CRC failed')
            os.replace(staging, output)
        finally:
            if os.path.exists(staging):
                os.unlink(staging)
        print(f'Patched {len(changes)} binaries; original entitlements retained. Re-sign ALL bundles with Feather: {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--dylib', type=Path, required=True)
    parser.add_argument('--ldid', default='ldid')
    args = parser.parse_args()
    patch(args.source, args.output, args.dylib, args.ldid)
