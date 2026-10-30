#!/usr/bin/env python3
"""Sign a release archive and its feed using the Moka key in macOS Keychain.

Usage: python3 Tools/make-appcast.py Moka-macOS.zip updates/appcast.xml
Only public signatures are written. Never export the private signing key.
"""
import datetime
import email.utils
import pathlib
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
archive, destination = map(pathlib.Path, sys.argv[1:])
sparkle = pathlib.Path(subprocess.check_output(["zsh", str(root / "Tools/fetch-sparkle.sh")], text=True).strip())
account = "fr.local.moka.updates"
with zipfile.ZipFile(archive) as package:
    info = plistlib.loads(package.read("Moka.app/Contents/Info.plist"))
version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
if not re.fullmatch(r"1\.\d+\.\d+", version) or not build.isdigit():
    raise SystemExit("Expected a 1.x.y release and an integer build number.")
key = subprocess.check_output([str(sparkle / "bin/generate_keys"), "--account", account, "-p"], text=True).strip()
if key != info["SUPublicEDKey"]:
    raise SystemExit("Signing key does not match the public key in this app.")
signer = str(sparkle / "bin/sign_update")
signature = subprocess.check_output([signer, "--account", account, "-p", str(archive)], text=True).strip()
subprocess.run([signer, "--account", account, "--verify", str(archive), signature], check=True)
namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", namespace)
rss = ET.Element("rss", version="2.0")
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = "Moka"
ET.SubElement(channel, "link").text = "https://github.com/theoduvivier/Moka"
ET.SubElement(channel, "description").text = "Mises à jour de Moka pour macOS"
ET.SubElement(channel, "language").text = "fr"
item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = f"Moka {version}"
ET.SubElement(item, "pubDate").text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
ET.SubElement(item, f"{{{namespace}}}version").text = build
ET.SubElement(item, f"{{{namespace}}}shortVersionString").text = version
ET.SubElement(item, f"{{{namespace}}}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
ET.SubElement(item, "description").text = "Une nouvelle version de Moka est disponible. L’installation relancera Moka et terminera la session en cours."
ET.SubElement(item, "enclosure", {
    "url": f"https://github.com/theoduvivier/Moka/releases/download/v{version}/Moka-macOS.zip",
    "length": str(archive.stat().st_size), "type": "application/octet-stream",
    f"{{{namespace}}}edSignature": signature,
})
ET.indent(rss)
destination.parent.mkdir(parents=True, exist_ok=True)
ET.ElementTree(rss).write(destination, encoding="utf-8", xml_declaration=True)
subprocess.run([signer, "--account", account, str(destination)], check=True)
subprocess.run([signer, "--account", account, "--verify", str(destination)], check=True)
print(f"Signed feed: {destination}")
