#!/usr/bin/env python3
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

root = pathlib.Path(__file__).resolve().parent.parent
version = sys.argv[1] if len(sys.argv) == 2 else ""
if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
    raise SystemExit("Usage: scripts/update-appcast.py <major.minor.patch>")

output = root / ".build/distribution" / version
dmg = output / f"MeetingTape-{version}-arm64.dmg"
if json.loads((output / "notary-result.json").read_text())["status"] != "Accepted":
    raise SystemExit("The update must have accepted notarization.")
subprocess.run(["xcrun", "stapler", "validate", str(dmg)], check=True)
with tempfile.TemporaryDirectory(prefix="meetingtape-update-feed-") as directory:
    mount = pathlib.Path(directory) / "dmg"
    mount.mkdir()
    subprocess.run(["hdiutil", "attach", str(dmg), "-readonly", "-nobrowse", "-mountpoint", str(mount)], check=True, stdout=subprocess.DEVNULL)
    try:
        app = mount / "MeetingTape.app"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    finally:
        subprocess.run(["hdiutil", "detach", str(mount)], check=True, stdout=subprocess.DEVNULL)
if info["CFBundleShortVersionString"] != version:
    raise SystemExit("The final DMG App version must match the release.")

tools = root / ".build/artifacts/meetingtape/Sparkle/bin"
account = "com.paaatrickfu.meetingtape"
public_key = subprocess.check_output([str(tools / "generate_keys"), "--account", account, "-p"], text=True).strip()
if public_key != info["SUPublicEDKey"]:
    raise SystemExit("The signing key must match the public key inside the release App.")

archives = output / "update-feed"
archives.mkdir(exist_ok=True)
published_feed = root / "docs/appcast.xml"
sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
if published_feed.exists():
    previous = ET.parse(published_feed)
    builds = [item.findtext(sparkle + "version") for item in previous.findall("./channel/item")]
    current = tuple(map(int, info["CFBundleVersion"].split(".")))
    if any(tuple(map(int, build.split("."))) >= current for build in builds if build):
        raise SystemExit("CFBundleVersion must increase beyond the published feed.")
    shutil.copy2(published_feed, archives / "appcast.xml")

sections = re.split(r"^## ", (root / "CHANGELOG.md").read_text(), flags=re.MULTILINE)
notes = next((section for section in sections[1:] if re.match(r"v?" + re.escape(version) + r"(?:\s|$)", section)), None)
if notes is None:
    raise SystemExit("Add this version's release notes to CHANGELOG.md first.")
shutil.copy2(dmg, archives / dmg.name)
(archives / (dmg.stem + ".md")).write_text("## " + notes)
download_prefix = f"https://github.com/patrick-fu/meetingtape/releases/download/v{version}/"
subprocess.run([
    str(tools / "generate_appcast"), "--account", account,
    "--download-url-prefix", download_prefix, "--embed-release-notes",
    "--link", "https://patrick-fu.github.io/meetingtape/",
    "--maximum-deltas", "0", str(archives),
], check=True)
feed = archives / "appcast.xml"
subprocess.run([str(tools / "sign_update"), "--account", account, "--verify", str(feed)], check=True)
items = ET.parse(feed).findall("./channel/item")
item = next(item for item in items if item.findtext(sparkle + "version") == info["CFBundleVersion"])
enclosure = item.find("enclosure")
if item.findtext(sparkle + "shortVersionString") != version or enclosure.get("url") != download_prefix + dmg.name or int(enclosure.get("length")) != dmg.stat().st_size:
    raise SystemExit("Generated update metadata does not match the final release DMG.")
subprocess.run([
    str(tools / "sign_update"), "--account", account, "--verify", str(dmg),
    enclosure.attrib[sparkle + "edSignature"],
], check=True)
shutil.copy2(feed, output / "appcast.xml")
print(f"Signed update feed: {output / 'appcast.xml'}")
print("Upload the final DMG to its release URL before publishing this feed to docs/appcast.xml.")
