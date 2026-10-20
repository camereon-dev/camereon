"""Assemble the static Pages site and resolve the newest downloadable beta."""

import argparse
import html
import json
import os
from pathlib import Path
import re
import shutil
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "site"
DESTINATION = ROOT / "dist" / "site"
REPOSITORY = "camereon-dev/camereon"
RELEASES_URL = f"https://github.com/{REPOSITORY}/releases"
APK_NAME = "camereon-beta-arm64.apk"


def release_metadata(offline):
    if offline:
        return {
            "version": "プレビュー",
            "apk_url": RELEASES_URL,
            "release_url": RELEASES_URL,
            "size": "ARM64 APK",
            "checksum_url": RELEASES_URL,
        }
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "camereon-pages-build",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = Request(
        f"https://api.github.com/repos/{REPOSITORY}/releases?per_page=100",
        headers=headers,
    )
    with urlopen(request, timeout=30) as response:
        releases = json.load(response)
    candidates = []
    for release in releases:
        if release["draft"] or not release["prerelease"]:
            continue
        if not re.fullmatch(r"v\d+\.\d+\.\d+-beta\.\d+", release["tag_name"]):
            continue
        assets = {
            asset["name"]: asset
            for asset in release["assets"]
            if asset["state"] == "uploaded"
        }
        if {APK_NAME, APK_NAME + ".sha256"}.issubset(assets):
            candidates.append((release, assets))
    if not candidates:
        raise RuntimeError("No published beta with an APK and checksum is available")
    release, assets = max(candidates, key=lambda item: item[0]["published_at"])
    apk = assets[APK_NAME]
    checksum = assets[APK_NAME + ".sha256"]
    prefix = f"https://github.com/{REPOSITORY}/releases/download/{release['tag_name']}/"
    if apk["browser_download_url"] != prefix + APK_NAME:
        raise ValueError("Unexpected beta APK download URL")
    if checksum["browser_download_url"] != prefix + APK_NAME + ".sha256":
        raise ValueError("Unexpected beta checksum URL")
    return {
        "version": release["tag_name"].removeprefix("v"),
        "apk_url": apk["browser_download_url"],
        "release_url": f"https://github.com/{REPOSITORY}/releases/tag/{release['tag_name']}",
        "size": f"{apk['size'] / 1_000_000:.1f} MB",
        "checksum_url": checksum["browser_download_url"],
        "published_at": release["published_at"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true", help="Preview without GitHub API access")
    arguments = parser.parse_args()
    metadata = release_metadata(arguments.offline)
    DESTINATION.mkdir(parents=True, exist_ok=True)
    shutil.copytree(SOURCE / "assets", DESTINATION / "assets", dirs_exist_ok=True)
    for name in ("styles.css", "app.js"):
        shutil.copyfile(SOURCE / name, DESTINATION / name)
    page = (SOURCE / "index.html").read_text()
    for key, value in metadata.items():
        page = page.replace("{{" + key.upper() + "}}", html.escape(value, quote=True))
    if re.search(r"\{\{[A-Z_]+\}\}", page):
        raise ValueError("Unresolved template value in site HTML")
    (DESTINATION / "index.html").write_text(page)
    (DESTINATION / ".nojekyll").touch()
    (DESTINATION / "release.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    print(f"Site ready: {DESTINATION} ({metadata['version']})")


if __name__ == "__main__":
    main()
