#!/usr/bin/env python3
"""Static check of a decrypted YouTube Music IPA for the app-local WireGuard build.

The transport patches in Source/WireGuard/YTMUWGTransport.m were derived from
YouTube Music 9.42.2. This script re-checks any other version before it is
trusted: it reports which of the classes and selectors the patches and loader
diagnostics rely on exist in the app's Mach-O images, whether the protobuf enum
value names for networkStackType are present (the runtime then picks the
URLSession value by name), and whether the executable is still encrypted.

It does not prove that a version behaves like 9.42.2. The authoritative check
is on the device: the in-app diagnostics record the loader actually used.

Usage: python3 tools/ytm_transport_scan.py YouTubeMusic.ipa [--markdown]
"""
import argparse
import plistlib
import re
import struct
import sys
import zipfile

CLASSES = [
    "YTIHamplayerUrlSessionDataLoaderConfig", "MLHAMDataLoaderProviderImpl", "HAMURLSessionDataLoader",
    "HAMEnvoyDataLoader", "HAMURLSessionDataLoadTask", "YTIOnesieConfig", "YTIInnerTubeUploadsConfig",
    "YTIMediaCommonConfig", "YTHotConfig", "EnvoyEngineImpl",
]
SELECTORS = [
    "networkStackType", "useCronet", "useCronetNative", "assumeHTTP3Capable", "enableCronet", "enableQuic",
    "cronetEnabled", "cronetQuicEnabled", "platypusUseEnvoyNetFetch", "onesiePlatypusUseEnvoyNetFetch",
    "updateDataLoader", "taskWithRequest:userInfo:", "didReceiveResponse:absoluteTime:",
    "didCompleteWithError:absoluteTime:",
]
VERIFIED = {"9.42.2"}

LC_SEGMENT_64, LC_ENCRYPTION_INFO_64 = 0x19, 0x2C
CPU_TYPE_ARM64 = 0x0100000C


def arm64_slice(data):
    magic = struct.unpack_from(">I", data)[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):  # fat
        count = struct.unpack_from(">I", data, 4)[0]
        wide = magic == 0xCAFEBABF
        for i in range(count):
            if wide:
                cpu, _, offset, size = struct.unpack_from(">iiQQ", data, 8 + i * 32)[:4]
            else:
                cpu, _, offset, size = struct.unpack_from(">iiII", data, 8 + i * 20)[:4]
            if cpu == CPU_TYPE_ARM64:
                return data[offset:offset + size]
        return None
    if struct.unpack_from("<I", data)[0] == 0xFEEDFACF:
        return data
    return None


def parse(data):
    """Return ({(segment, section): bytes}, encrypted) for a thin 64-bit Mach-O."""
    ncmds = struct.unpack_from("<I", data, 16)[0]
    offset, sections, encrypted = 32, {}, False
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            for i in range(nsects):
                s = offset + 72 + i * 80
                sect = data[s:s + 16].split(b"\0")[0].decode(errors="replace")
                seg = data[s + 16:s + 32].split(b"\0")[0].decode(errors="replace")
                sz = struct.unpack_from("<Q", data, s + 40)[0]
                fo = struct.unpack_from("<I", data, s + 48)[0]
                if fo and sz:
                    sections[(seg, sect)] = data[fo:fo + sz]
        elif cmd == LC_ENCRYPTION_INFO_64 and struct.unpack_from("<I", data, offset + 16)[0]:
            encrypted = True
        offset += size
    return sections, encrypted


def scan(ipa_path):
    with zipfile.ZipFile(ipa_path) as z:
        names = z.namelist()
        info_name = next(n for n in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n))
        app = info_name[:-len("Info.plist")]
        info = plistlib.loads(z.read(info_name))
        images = [app + info["CFBundleExecutable"]]
        for n in names:
            m = re.fullmatch(re.escape(app) + r"Frameworks/([^/]+)\.framework/\1", n)
            if m or (n.startswith(app + "Frameworks/") and n.endswith(".dylib") and n.count("/") == 3):
                images.append(n)
        found = {"classes": {}, "selectors": {}}
        enum_names, encrypted = set(), []
        for image in images:
            data = arm64_slice(z.read(image))
            if not data:
                continue
            sections, enc = parse(data)
            if enc:
                encrypted.append(image[len(app):])
            classnames = sections.get(("__TEXT", "__objc_classname"), b"")
            methnames = sections.get(("__TEXT", "__objc_methname"), b"")
            cstrings = sections.get(("__TEXT", "__cstring"), b"")
            # Apple clang emits class names in __objc_classname; other compilers
            # may use __cstring.
            names_blob = b"\0" + classnames + b"\0" + cstrings
            for c in CLASSES:
                if b"\0" + c.encode() + b"\0" in names_blob:
                    found["classes"].setdefault(c, []).append(image[len(app):])
            for s in SELECTORS:
                if b"\0" + s.encode() + b"\0" in b"\0" + methnames:
                    found["selectors"].setdefault(s, []).append(image[len(app):])
            for blob in (cstrings, sections.get(("__TEXT", "__const"), b"")):
                for m in re.finditer(rb"[A-Z0-9_]*NETWORK_STACK[A-Z0-9_]*", blob):
                    enum_names.add(m.group().decode())
    return {
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "bundle_id": info.get("CFBundleIdentifier"),
        "images_scanned": len(images),
        "encrypted_images": encrypted,
        "found": found,
        "network_stack_enum_names": sorted(enum_names),
    }


def report(r, markdown=False):
    lines = []
    add = lines.append
    add(f"## App-local WireGuard transport scan: YouTube Music {r['version']} ({r['build']})" if markdown
        else f"YouTube Music {r['version']} ({r['build']}) {r['bundle_id']}, {r['images_scanned']} Mach-O images")
    if r["encrypted_images"]:
        add(f"- ENCRYPTED images (use a decrypted IPA): {', '.join(r['encrypted_images'])}")
    verified = r["version"] in VERIFIED
    add(f"- networkStackType mapping verified for this version: {'yes' if verified else 'no (runtime decides: enum names, else observe only)'}")
    for kind, wanted in (("classes", CLASSES), ("selectors", SELECTORS)):
        for name in wanted:
            where = r["found"][kind].get(name)
            add(f"- {kind[:-2] if kind == 'classes' else 'selector'} `{name}`: {'present in ' + ', '.join(where) if where else 'NOT FOUND'}")
    names = r["network_stack_enum_names"]
    add(f"- protobuf NETWORK_STACK enum names in binary: {', '.join(names) if names else 'none (stripped)'}")
    if any("URL_SESSION" in n or "URLSESSION" in n for n in names):
        add("- => the runtime patch can choose the URLSession value by enum name")
    elif not verified:
        add("- => no URLSession enum name and version not verified: the patch only observes; "
            "enable the in-app override only if diagnostics show Envoy loader tasks")
    add("- This is a static presence check. Playback must still be verified on a device.")
    return "\n".join(lines)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("ipa")
    p.add_argument("--markdown", action="store_true")
    a = p.parse_args()
    try:
        print(report(scan(a.ipa), a.markdown))
    except (KeyError, StopIteration, zipfile.BadZipFile, struct.error) as e:
        print(f"scan failed: {e!r}", file=sys.stderr)
        sys.exit(1)
