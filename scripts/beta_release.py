"""Build metadata, verify signed APKs, and publish repeatable beta releases."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


APK_NAME = "camereon-beta-arm64.apk"
BETA_DIR = Path("dist/beta")


def required(name):
    value = os.environ.get(name, "")
    if not value:
        raise ValueError(f"{name} is required")
    return value


def build_version():
    number = required("GITHUB_RUN_NUMBER")
    if not number.isdigit() or not 0 < int(number) <= 2_100_000_000:
        raise ValueError("Invalid Android build number")
    match = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)",
                      Path("pubspec.yaml").read_text(), re.MULTILINE)
    if not match:
        raise ValueError("pubspec.yaml must contain a numeric base version")
    return f"{match[1]}-beta.{int(number)}"


def output(name, value):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as stream:
            stream.write(f"{name}={value}\n")


def restore_key():
    key = base64.b64decode(required("CAMEREON_BETA_KEYSTORE_BASE64"), validate=True)
    path = Path(required("RUNNER_TEMP")) / "camereon-beta-signing.p12"
    path.touch(mode=0o600)
    path.chmod(0o600)
    path.write_bytes(key)
    output("keystore", str(path))


def android_tool(name):
    sdk = Path(required("ANDROID_HOME"))
    versions = [p for p in (sdk / "build-tools").iterdir()
                if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", p.name) and (p / name).is_file()]
    if not versions:
        raise ValueError(f"Android build tool {name} is unavailable")
    return str(max(versions, key=lambda p: tuple(map(int, p.name.split(".")))) / name)


def package():
    version = build_version()
    commit = required("GITHUB_SHA")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Invalid source commit")
    expected_cert = required("CAMEREON_BETA_CERT_SHA256").lower()
    if not re.fullmatch(r"[0-9a-f]{64}", expected_cert):
        raise ValueError("Invalid expected signing certificate")
    source = Path("dist/camereon-demo.apk")
    signatures = subprocess.check_output(
        [android_tool("apksigner"), "verify", "--print-certs-pem", str(source)], text=True)
    # SDK versions use different signer labels and may repeat a certificate
    # for several Android API ranges. Compare the actual certificate bytes.
    certificates = re.findall(
        r"-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----",
        signatures, re.DOTALL)
    fingerprints = {
        hashlib.sha256(base64.b64decode(re.sub(r"\s+", "", cert), validate=True)).hexdigest()
        for cert in certificates
    }
    if fingerprints != {expected_cert}:
        raise ValueError(f"Unexpected APK signing certificate: {sorted(fingerprints)}")
    manifest = subprocess.check_output(
        [android_tool("aapt"), "dump", "badging", str(source)], text=True)
    package_info = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", manifest)
    expected = ("dev.camereon.camereon.demo", str(int(required("GITHUB_RUN_NUMBER"))), version)
    if not package_info or package_info.groups() != expected:
        raise ValueError("APK package or version does not match the beta release")
    native_code = re.search(r"^native-code: (.+)$", manifest, re.MULTILINE)
    if not native_code or native_code.group(1).strip() != "'arm64-v8a'":
        raise ValueError("Beta APK must contain ARM64 native libraries only")
    BETA_DIR.mkdir(parents=True, exist_ok=True)
    apk = BETA_DIR / APK_NAME
    shutil.copyfile(source, apk)
    digest = hashlib.sha256(apk.read_bytes()).hexdigest()
    apk.with_name(APK_NAME + ".sha256").write_text(f"{digest}  {APK_NAME}\n")
    metadata = {
        "version": version, "tag": f"v{version}", "commit": commit,
        "build_number": int(required("GITHUB_RUN_NUMBER")),
        "apk_name": APK_NAME, "sha256": digest, "certificate_sha256": expected_cert,
    }
    (BETA_DIR / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
    output("tag", metadata["tag"])
    output("version", version)
    print(f"Verified signed beta APK: {version}")


def api(path, optional=False):
    result = subprocess.run(["gh", "api", path], text=True, capture_output=True)
    if result.returncode:
        try:
            missing = str(json.loads(result.stdout).get("status")) == "404"
        except json.JSONDecodeError:
            missing = False
        if optional and missing:
            return None
        raise RuntimeError(f"GitHub API request failed: {path}\n{result.stderr}")
    return json.loads(result.stdout)


def check_tag(repo, tag, commit):
    ref = api(f"repos/{repo}/git/ref/tags/{tag}", optional=True)
    if ref is None:
        return
    obj = ref["object"]
    for _ in range(10):
        if obj["type"] != "tag":
            break
        obj = api(f"repos/{repo}/git/tags/{obj['sha']}")["object"]
    if obj["type"] != "commit" or obj["sha"] != commit:
        raise ValueError("Existing beta tag points to a different source commit")


def publish():
    if required("GITHUB_REF") != "refs/heads/main" or required("GITHUB_EVENT_NAME") not in {"push", "workflow_dispatch"}:
        raise ValueError("Beta releases can only be published from main")
    repo = required("GITHUB_REPOSITORY")
    metadata = json.loads((BETA_DIR / "release.json").read_text())
    tag, commit = metadata["tag"], metadata["commit"]
    if metadata["version"] != build_version() or tag != f"v{build_version()}" or commit != required("GITHUB_SHA"):
        raise ValueError("Release metadata does not match this workflow run")
    if metadata["apk_name"] != APK_NAME:
        raise ValueError("Unexpected release APK name")
    apk = BETA_DIR / APK_NAME
    checksum = apk.with_name(APK_NAME + ".sha256")
    digest = hashlib.sha256(apk.read_bytes()).hexdigest()
    if digest != metadata["sha256"] or checksum.read_text() != f"{digest}  {APK_NAME}\n":
        raise ValueError("Release APK checksum mismatch")
    check_tag(repo, tag, commit)
    existing = api(f"repos/{repo}/releases/tags/{tag}", optional=True)
    if existing and existing["target_commitish"] != commit:
        raise ValueError("Existing release targets a different source commit")
    expected_assets = {APK_NAME, APK_NAME + ".sha256"}
    if existing and not existing["draft"]:
        if not existing["prerelease"] or not expected_assets.issubset({a["name"] for a in existing["assets"]}):
            raise ValueError("Published release is not a complete beta release")
        url = existing["html_url"]
    else:
        notes = BETA_DIR / "release-notes.md"
        notes.write_text(
            f"camereon {metadata['version']} のベータ版です。\n\n"
            "撮影後に写真を読み込めない問題への互換性修正と、AIモデルの一時停止・途中再開を追加しました。画面を移動しても取得は継続し、アプリ終了後も保存済みの続きから再開できます。\n\n"
            "撮影した写真をドラッグして複数箇所を黒塗りし、保存前に確認してギャラリーへ JPEG として保存できます。取り消し・全リセットにも対応しています。\n\n起動画面の「サンプルで試す」から、架空の配送ラベルで黒塗り・保存を体験できます。カメラの許可や AI モデルは不要です。\n\n"
            f"Android 11 以上の ARM64 端末で `{APK_NAME}` を開いてインストールしてください。\n"
            "任意の追加機能として、Gemma 4 による端末内の写真の内容説明を利用できます。初回の AI 利用には約2.6GBのモデル取得と作業領域が必要です。写真は端末内で処理します。自動検出・自動黒塗りには対応していません。\n"
            "以後のベータ版は同じ署名鍵で更新できます。\n\n"
            f"ソース: `{commit}`\n"
        )
        if not existing:
            subprocess.run(["gh", "release", "create", tag, "--repo", repo,
                            "--target", commit, "--draft", "--prerelease", "--latest=false",
                            "--title", f"camereon {metadata['version']} (beta)",
                            "--notes-file", str(notes)], check=True)
        subprocess.run(["gh", "release", "upload", tag, str(apk), str(checksum),
                        "--repo", repo, "--clobber"], check=True)
        subprocess.run(["gh", "release", "edit", tag, "--repo", repo,
                        "--draft=false", "--prerelease", "--latest=false",
                        "--notes-file", str(notes)], check=True)
        check_tag(repo, tag, commit)
        published = api(f"repos/{repo}/releases/tags/{tag}")
        if published["draft"] or not published["prerelease"]:
            raise ValueError("Beta release was not published correctly")
        url = published["html_url"]
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as stream:
            stream.write(f"## Beta release\n[{tag}]({url})\n")
    print(url)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["version", "restore-key", "package", "publish"])
    command = parser.parse_args().command
    if command == "version":
        print(build_version())
    elif command == "restore-key":
        restore_key()
    elif command == "package":
        package()
    else:
        publish()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
