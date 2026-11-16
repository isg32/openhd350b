#!/usr/bin/env python3
"""
sennheiser_fw.py — download & decrypt Sennheiser Smart Control firmware packages.

Reverse-engineered from Smart Control 4.7.0 (NativeScript bundle.js). For use with
hardware you own (e.g. HD 350BT / SEBT3). Run it on your OWN machine — it needs
internet access to Sennheiser's firmware cloud.

Pipeline (exactly what the app does):
  1. GET  https://api.s-consumer-cloud.com/firmware/api/v2/updates/<hwId>/<curVer>?hw_revision=<rev>&...
  2. response.data.packages[].url  ->  a <name>.zip.enc on firmware.s-consumer-cloud.com
  3. AES-256-CTR decrypt (key below, counter starts at 5)  ->  <name>.zip
  4. unzip  ->  the raw firmware image that gets pushed to the chip over GAIA

The AES key is hardcoded in the app, so the .enc is only transport obfuscation.
NOTE: the firmware image itself is signed and validated ON the Qualcomm chip at
install time — decrypting it lets you *study* it, not forge a modified build.

Deps:  pip install pycryptodome requests
"""
import argparse, json, os, sys, zipfile
from Crypto.Cipher import AES
from Crypto.Util import Counter

# --- constants lifted verbatim from the app ---------------------------------
AES_KEY = bytes.fromhex("ed3b78a474c2acabb812407b97065649bf190e3d758e86f17b920aa41d8c271e")
CTR_INITIAL = 5                      # new Counter(5) in aes-js
API_BASE = "https://api.s-consumer-cloud.com/firmware/api/v2"
# platform params the app always appends (apiVersion>=2)
PLATFORM = {"osType": "android", "osVersion": "13", "appVersion": "4.7.0", "appFlavor": "prod"}


def decrypt_enc(enc_bytes: bytes) -> bytes:
    ctr = Counter.new(128, initial_value=CTR_INITIAL)
    return AES.new(AES_KEY, AES.MODE_CTR, counter=ctr).decrypt(enc_bytes)


def cmd_decrypt(args):
    """Offline: decrypt a .zip.enc you already have (e.g. from a proxy capture)."""
    data = open(args.infile, "rb").read()
    out = decrypt_enc(data)
    zip_path = args.outfile or args.infile.replace(".enc", "")
    open(zip_path, "wb").write(out)
    print(f"[+] decrypted -> {zip_path} ({len(out)} bytes)")
    _maybe_unzip(zip_path)


def _maybe_unzip(zip_path):
    if zipfile.is_zipfile(zip_path):
        d = zip_path + ".extracted"
        os.makedirs(d, exist_ok=True)
        with zipfile.ZipFile(zip_path) as z:
            z.extractall(d)
            names = z.namelist()
        print(f"[+] unzipped {len(names)} file(s) -> {d}")
        for n in names:
            print("      ", n)
    else:
        print("[i] not a zip (already the raw image, or wrong key/counter)")


def cmd_check(args):
    """Online: ask the cloud what updates exist for a device, print the packages."""
    import requests
    url = f"{API_BASE}/updates/{args.hwid}/{args.version}"
    params = dict(PLATFORM)
    if args.hw_revision:
        params["hw_revision"] = args.hw_revision
    print(f"[*] GET {url}")
    r = requests.get(url, params=params, headers={"Content-Type": "application/json"}, timeout=30)
    print(f"[*] HTTP {r.status_code}")
    try:
        j = r.json()
    except Exception:
        print(r.text[:2000]); return
    print(json.dumps(j, indent=2)[:4000])
    pkgs = (j.get("data") or {}).get("packages") or []
    if pkgs and args.download:
        _download_and_decrypt(pkgs[0].get("url"), args.outdir)


def cmd_fetch(args):
    """Online: download a package .enc straight from its URL and decrypt it."""
    _download_and_decrypt(args.url, args.outdir)


def _download_and_decrypt(url, outdir):
    import requests
    if not url:
        print("[!] no package url"); return
    os.makedirs(outdir, exist_ok=True)
    fn = url.split("/")[-1]
    enc_path = os.path.join(outdir, fn)
    print(f"[*] downloading {url}")
    r = requests.get(url, timeout=120); r.raise_for_status()
    open(enc_path, "wb").write(r.content)
    print(f"[+] saved {enc_path} ({len(r.content)} bytes)")
    if enc_path.endswith(".enc"):
        out = decrypt_enc(r.content)
        zip_path = enc_path[:-4]
        open(zip_path, "wb").write(out)
        print(f"[+] decrypted -> {zip_path}")
        _maybe_unzip(zip_path)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("decrypt", help="decrypt a local .zip.enc (offline)")
    d.add_argument("infile"); d.add_argument("outfile", nargs="?")
    d.set_defaults(func=cmd_decrypt)

    c = sub.add_parser("check", help="query cloud for updates for a device")
    c.add_argument("hwid", help="hardwareIdentifier (read from the device / proxy capture)")
    c.add_argument("version", help="current systemRelease/firmware version, e.g. 2.1.0")
    c.add_argument("--hw-revision", dest="hw_revision", default=None)
    c.add_argument("--download", action="store_true", help="also download+decrypt packages[0]")
    c.add_argument("--outdir", default="fw_out")
    c.set_defaults(func=cmd_check)

    f = sub.add_parser("fetch", help="download+decrypt a package from its direct URL")
    f.add_argument("url"); f.add_argument("--outdir", default="fw_out")
    f.set_defaults(func=cmd_fetch)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
