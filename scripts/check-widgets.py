#!/usr/bin/env python3
"""Check that repackaging retains the supplied, decrypted WidgetKit extensions.

Does not establish that a later signing service grants shared App Groups.
"""
import argparse
import plistlib
import zipfile


def widgets(path):
    with zipfile.ZipFile(path) as archive:
        hosts = [n for n in archive.namelist()
                 if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/Info.plist')]
        if len(hosts) != 1:
            raise ValueError('IPA must contain exactly one host app')
        host = hosts[0].removesuffix('Info.plist')
        host_id = plistlib.loads(archive.read(hosts[0]))['CFBundleIdentifier']
        found = {}
        for name in archive.namelist():
            if not name.startswith(host + 'PlugIns/') or not name.endswith('.appex/Info.plist'):
                continue
            info = plistlib.loads(archive.read(name))
            if info.get('NSExtension', {}).get('NSExtensionPointIdentifier') != 'com.apple.widgetkit-extension':
                continue
            executable = info.get('CFBundleExecutable', '')
            binary = name.removesuffix('Info.plist') + executable
            if not executable or binary not in archive.namelist():
                raise ValueError('Widget executable missing: ' + name)
            identifier = info.get('CFBundleIdentifier', '')
            if not identifier.startswith(host_id + '.'):
                raise ValueError('Widget bundle ID must be a child of host: ' + identifier)
            found[name.removeprefix(host)] = identifier
        if not found:
            raise ValueError('No WidgetKit extension in IPA. Supply an IPA that includes the decrypted widget; the tweak cannot recreate it.')
        return found


def check(source, output):
    before, after = widgets(source), widgets(output)
    if before.keys() != after.keys():
        raise ValueError('Widget extensions changed during packaging')
    return after


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('output')
    args = parser.parse_args()
    for path, identifier in check(args.source, args.output).items():
        print(f'Preserved widget: {path} ({identifier})')
    print('Final signer must preserve the widget and grant the SAME App Group to host and widget. Presence alone does not verify signing or rendered content.')
