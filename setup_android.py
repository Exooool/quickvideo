"""Generate or repair the Android scaffold for this Flutter app."""

import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ANDROID = "{http://schemas.android.com/apk/res/android}"
ET.register_namespace("android", ANDROID[1:-1])
MANIFEST = Path("android/app/src/main/AndroidManifest.xml")
MIN_SDK = re.compile(
    r"^(\s*minSdk(?:Version)?\s*(?:=\s*)?)(flutter\.minSdkVersion|\d+)\b",
    re.MULTILINE,
)


def create_android(root, flutter, project_name):
    # Keep the existing app files when Flutter adds platform templates.
    paths = [root / "pubspec.yaml", *sorted((root / "lib").glob("*.dart"))]
    saved = {path: path.read_bytes() for path in paths}
    template_test = root / "test" / "widget_test.dart"
    had_test = template_test.exists()
    try:
        subprocess.run([
            flutter, "create", "--platforms=android", "--no-pub",
            "--org=com.miralume", f"--project-name={project_name}", ".",
        ], cwd=root, check=True)
    finally:
        for path, data in saved.items():
            if not path.exists() or path.read_bytes() != data:
                path.write_bytes(data)
        if not had_test:
            template_test.unlink(missing_ok=True)


def migrate_main_activity(main):
    for path in (*main.rglob("MainActivity.kt"), *main.rglob("MainActivity.java")):
        previous = path.read_text(encoding="utf-8")
        updated = re.sub(
            r"\bio\.flutter\.app\.(Flutter(?:Fragment)?Activity)\b",
            r"io.flutter.embedding.android.\1",
            previous,
        )
        if updated == previous:
            continue
        updated = re.sub(
            r"(?m)^[ \t]*GeneratedPluginRegistrant\.registerWith\(this\);?[ \t]*\n",
            "", updated,
        )
        if not re.search(r"\bGeneratedPluginRegistrant\.", updated):
            updated = re.sub(
                r"(?m)^import io\.flutter\.plugins\.GeneratedPluginRegistrant;?[ \t]*\n",
                "", updated,
            )
        path.write_text(updated, encoding="utf-8")


def configure_android(root):
    path = root / MANIFEST
    if not path.is_file():
        raise ValueError(f"Android 初始化后仍找不到 {path}。")
    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
    manifest = ET.parse(path, parser=parser)
    document = manifest.getroot()
    application = document.find("application")
    if application is None:
        raise ValueError(f"{path} 缺少 application 节点。")
    if application.get(ANDROID + "name") == "io.flutter.app.FlutterApplication":
        application.set(ANDROID + "name", "${applicationName}")
    application.set(ANDROID + "label", "quick video")

    # Flutter reads the main manifest before Gradle merges build variants.
    for parent in document.iter():
        for node in parent.findall("meta-data"):
            if node.get(ANDROID + "name") == "flutterEmbedding":
                parent.remove(node)
    ET.SubElement(application, "meta-data", {
        ANDROID + "name": "flutterEmbedding", ANDROID + "value": "2",
    })
    if not any(node.get(ANDROID + "name") == "android.permission.INTERNET"
               for node in document.findall("uses-permission")):
        document.insert(0, ET.Element("uses-permission", {
            ANDROID + "name": "android.permission.INTERNET",
        }))

    if not application.get(ANDROID + "networkSecurityConfig"):
        application.set(ANDROID + "networkSecurityConfig", "@xml/network_security_config")
        resource = path.parent / "res" / "xml" / "network_security_config.xml"
        if not resource.exists():
            resource.parent.mkdir(parents=True, exist_ok=True)
            resource.write_text(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                '<network-security-config>\n'
                '  <base-config cleartextTrafficPermitted="false"/>\n'
                '  <domain-config cleartextTrafficPermitted="true">\n'
                '    <domain includeSubdomains="false">127.0.0.1</domain>\n'
                '    <domain includeSubdomains="false">localhost</domain>\n'
                '  </domain-config>\n'
                '</network-security-config>\n',
                encoding="utf-8",
            )
    if application.get(ANDROID + "networkSecurityConfig") == "@xml/network_security_config":
        resource = path.parent / "res" / "xml" / "network_security_config.xml"
        if resource.is_file():
            old = resource.read_bytes()
            updated = re.sub(
                rb"<domain>(127\.0\.0\.1|localhost)</domain>",
                rb'<domain includeSubdomains="false">\1</domain>',
                old,
            )
            if old != updated:
                resource.write_bytes(updated)
    ET.indent(manifest)
    buffer = ET.tostring(document, encoding="utf-8", xml_declaration=True) + b"\n"
    if path.read_bytes() != buffer:
        path.write_bytes(buffer)
    migrate_main_activity(path.parent)

    app = root / "android" / "app"
    gradle = next((entry for entry in (app / "build.gradle", app / "build.gradle.kts")
                   if entry.is_file()), None)
    if gradle is None:
        raise ValueError(f"{app} 缺少 build.gradle 或 build.gradle.kts。")
    old = gradle.read_bytes().decode("utf-8")
    new = MIN_SDK.sub(
        lambda match: match[1] + (
            str(max(24, int(match[2]))) if match[2].isdecimal() else "24"
        ),
        old,
        count=1,
    )
    if new != old:
        gradle.write_bytes(new.encode("utf-8"))


def main():
    root = Path.cwd()
    if not (root / "pubspec.yaml").is_file():
        root = Path(__file__).resolve().parent
    pubspec = root / "pubspec.yaml"
    if not pubspec.is_file():
        raise SystemExit("请在含有 pubspec.yaml 的 Flutter 项目根目录运行此脚本。")
    name = re.search(r"(?m)^name:\s*([a-z][a-z0-9_]*)\s*(?:#[^\n]*)?$",
                     pubspec.read_text(encoding="utf-8-sig"))
    if not name:
        raise SystemExit("无法从 pubspec.yaml 读取 Flutter 项目名。")
    flutter = shutil.which("flutter")
    if not flutter:
        raise SystemExit("请先安装 Flutter SDK，并将 flutter 加入 PATH。")
    try:
        android = root / "android"
        if (not (root / MANIFEST).is_file()
                or not any((android / name).is_file() for name in ("build.gradle", "build.gradle.kts"))):
            create_android(root, flutter, name[1])
        configure_android(root)
        subprocess.run([flutter, "pub", "get"], cwd=root, check=True)
    except (ValueError, OSError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"Android 项目配置失败：{error}", file=sys.stderr)
        raise SystemExit(1) from None
    print("Android embedding v2 配置完成。现在可运行 flutter build apk --release。")


if __name__ == "__main__":
    main()
