"""Personal video-source gateway. Configure sources before starting the server."""

import argparse
import json
import mimetypes
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor, wait
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urljoin, urlsplit
from urllib.request import Request, urlopen

from tvbox import find_works, read_episodes, read_subscription

ROOT = Path(__file__).resolve().parent
MAX_DOWNLOAD = 3 * 1024 * 1024
FETCH_TIMEOUT = 5
CATALOG_TTL = 120
ASSETS = {"demo.mp4", "demo_alt.mp4"}
ATTR = re.compile(r'([\w-]+)="([^"]*)"')


def media_url(value, base=""):
    url = urljoin(base, value)
    parsed = urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username is not None:
        raise ValueError("需要 HTTP 或 HTTPS 地址")
    return url


def fetch(url):
    request = Request(media_url(url), headers={"User-Agent": "OlaVideo/0.1"})
    with urlopen(request, timeout=FETCH_TIMEOUT) as response:
        data = response.read(MAX_DOWNLOAD + 1)
        if len(data) > MAX_DOWNLOAD:
            raise ValueError("来源响应过大")
        encoding = response.headers.get_content_charset() or "utf-8-sig"
        return data.decode(encoding), response.geturl()


class VideoPage(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_video = False
        self.candidates = []

    def handle_starttag(self, tag, attrs):
        attr = dict(attrs)
        if tag == "video":
            self.in_video = True
        if tag == "video" or (tag == "source" and self.in_video):
            self.candidates.append((attr.get("src"), attr.get("type")))
        if tag == "meta" and attr.get("property") in {"og:video", "og:video:url", "og:video:secure_url"}:
            self.candidates.append((attr.get("content"), None))

    def handle_endtag(self, tag):
        if tag == "video":
            self.in_video = False


def stream_format(url, mime=None):
    path = urlsplit(url).path.lower()
    if path.endswith(".m3u8") or "mpegurl" in (mime or "").lower():
        return "hls"
    if path.endswith(".mp4") or mime == "video/mp4":
        return "mp4"
    return "auto"


def parse_m3u(raw, base):
    lines = raw.splitlines()
    if not lines or not lines[0].strip().startswith("#EXTM3U"):
        raise ValueError("需要扩展 M3U 目录")
    if any(line.startswith("#EXT-X-") for line in lines):
        raise ValueError("单条 HLS 播放地址应放入 JSON 目录")
    items = []
    pending = None
    for line in lines[1:]:
        line = line.strip()
        if line.startswith("#EXTINF:"):
            parts = re.split(r',(?=(?:[^"]*"[^"]*")*[^"]*$)', line, maxsplit=1)
            attrs = dict(ATTR.findall(parts[0]))
            title = parts[1].strip() if len(parts) == 2 else ""
            if title:
                url_key = attrs.get("tvg-id") or title
                pending = {"id": url_key, "title": title, "episode": "正片"}
            else:
                pending = None
        elif line and not line.startswith("#") and pending:
            items.append({**pending, "url": media_url(line, base)})
            pending = None
    return items


class Catalog:
    def __init__(self, specs):
        self.specs = specs
        self.cache = {}
        self.lock = threading.Lock()
        self.pool = ThreadPoolExecutor(max_workers=12)
        self.details = {}

    def read(self, spec):
        source_id = spec["id"]
        with self.lock:
            cached = self.cache.get(source_id)
            if cached and time.monotonic() - cached[0] < CATALOG_TTL:
                return cached[1]

        if "items" in spec:
            rows, base = spec["items"], ""
        else:
            raw, base = fetch(spec["url"])
            rows = parse_m3u(raw, base) if spec.get("type") == "m3u" else json.loads(raw)
        result = []
        ids = set()
        for row in rows:
            item_id = str(row["id"])
            if item_id in ids:
                raise ValueError(f"来源有重复条目 ID：{item_id}")
            ids.add(item_id)
            playback = {}
            if "url" in row:
                playback["url"] = media_url(row["url"], base)
            elif "pageUrl" in row:
                playback["pageUrl"] = media_url(row["pageUrl"], base)
            elif row.get("demoAsset") in ASSETS and source_id.startswith("demo-"):
                playback["demoAsset"] = row["demoAsset"]
            else:
                continue
            result.append({
                **playback, "id": item_id, "sourceId": source_id,
                "sourceName": spec["name"], "title": row["title"],
                "workId": row.get("workId"), "year": str(row.get("year", "")),
                "kind": row.get("kind", "视频"), "episode": row.get("episode", "正片"),
                "episodeId": str(row.get("episodeId", row.get("episode", "正片"))),
                "format": row.get("format"),
            })
        with self.lock:
            self.cache[source_id] = (time.monotonic(), result)
        return result

    def search_source(self, spec, query):
        if spec.get("type") == "tvbox-cms":
            return find_works(spec, query, fetch)
        return [
            {key: value for key, value in row.items()
             if key not in {"url", "pageUrl", "demoAsset", "format"}}
            for row in self.read(spec) if query.casefold() in row["title"].casefold()
        ]

    def search(self, query):
        futures = [self.pool.submit(self.search_source, spec, query) for spec in self.specs]
        done, pending = wait(futures, timeout=6)
        for future in pending:
            future.cancel()
        matched, unavailable = [], []
        for spec, future in zip(self.specs, futures):
            if future in done:
                try:
                    matched.extend(future.result())
                    continue
                except Exception as exc:
                    print(f"Source {spec['id']}: {exc}", flush=True)
            unavailable.append(spec["name"])
        return {"items": matched, "unavailable": unavailable}

    def source(self, source_id):
        return next((spec for spec in self.specs if spec["id"] == source_id), None)

    def detail(self, source_id, work_id, *, refresh=False):
        spec = self.source(source_id)
        if not spec or spec.get("type") != "tvbox-cms":
            raise KeyError(source_id)
        key = (source_id, work_id)
        with self.lock:
            cached = self.details.get(key)
            if not refresh and cached and time.monotonic() - cached[0] < CATALOG_TTL:
                return cached[1]
        rows = read_episodes(spec, work_id, fetch, media_url, stream_format)
        with self.lock:
            if key not in self.details and len(self.details) >= 256:
                del self.details[next(iter(self.details))]
            self.details[key] = (time.monotonic(), rows)
        return rows

    def resolve(self, source_id, item_id):
        spec = self.source(source_id)
        if spec and spec.get("type") == "tvbox-cms":
            try:
                work_id, _, _ = json.loads(item_id)
                if not isinstance(work_id, str):
                    raise ValueError("invalid ID")
            except (ValueError, TypeError):
                raise KeyError(item_id) from None
            rows = self.detail(source_id, work_id, refresh=True)
            item = next((row for row in rows if row["id"] == item_id), None)
            if item is None:
                raise KeyError(item_id)
            return {"url": item["url"], "format": item["format"]}
        item = next((row for row in self.read(spec) if row["id"] == item_id), None) if spec else None
        if not item:
            raise KeyError("找不到该线路")
        if "demoAsset" in item:
            return {"assetPath": f"/video/{item['demoAsset']}", "format": "mp4"}
        if "url" in item:
            return {"url": item["url"], "format": item["format"] or stream_format(item["url"])}
        raw, base = fetch(item["pageUrl"])
        parser = VideoPage()
        parser.feed(raw)
        for value, mime in parser.candidates:
            if not value:
                continue
            try:
                url = media_url(value, base)
            except ValueError:
                continue
            format_name = stream_format(url, mime)
            if format_name != "auto":
                return {"url": url, "format": format_name}
        raise ValueError("网页没有直接提供可播放的 MP4 或 HLS 地址")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.route(head_only=False)

    def do_HEAD(self):
        self.route(head_only=True)

    def route(self, head_only):
        path = urlsplit(self.path)
        query = parse_qs(path.query)
        try:
            if path.path.startswith("/video/") and path.path[7:] in ASSETS:
                return self.send_demo(path.path[7:], head_only)
            if path.path == "/health":
                return self.send_json(200, {"ok": True}, head_only)
            if path.path == "/search":
                return self.send_json(200, self.server.catalog.search(query.get("q", [""])[0].strip()), head_only)
            if path.path == "/detail":
                src = query.get("source", [""])[0]
                work = query.get("id", [""])[0]
                rows = self.server.catalog.detail(src, work)
                items = [{k: v for k, v in row.items() if k not in {"url", "format"}} for row in rows]
                return self.send_json(200, {"items": items}, head_only)
            if path.path == "/resolve":
                result = self.server.catalog.resolve(query.get("source", [""])[0], query.get("id", [""])[0])
                return self.send_json(200, result, head_only)
            self.send_json(404, {"error": "未知接口"}, head_only)
        except KeyError:
            self.send_json(404, {"error": "找不到该线路"}, head_only)
        except (OSError, ValueError) as exc:
            print(f"Request failed: {exc}", flush=True)
            self.send_json(502, {"error": "当前线路无法解析"}, head_only)

    def send_json(self, status, value, head_only):
        payload = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if not head_only:
            self.wfile.write(payload)

    def send_demo(self, name, head_only):
        data = (ROOT.parent / "assets" / name).read_bytes()
        header = self.headers.get("Range")
        start, end = 0, len(data) - 1
        if header:
            requested = re.fullmatch(r"bytes=(\d*)-(\d*)", header)
            if requested and requested[1]:
                start = int(requested[1])
                end = min(int(requested[2]), end) if requested[2] else end
            elif requested and requested[2] and int(requested[2]):
                start = max(0, len(data) - int(requested[2]))
            else:
                start = len(data)
            if start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{len(data)}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
        self.send_response(206 if header else 200)
        self.send_header("Content-Type", mimetypes.guess_type(name)[0])
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if header:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.end_headers()
        if not head_only:
            self.wfile.write(data[start:end + 1])


def main():
    cli = argparse.ArgumentParser()
    cli.add_argument("--config", type=Path, default=ROOT / "sources.example.json")
    cli.add_argument("--host", default="127.0.0.1")
    cli.add_argument("--port", type=int, default=8765)
    cli.add_argument("--tvbox", action="append", default=[], metavar="URL",
                     help="导入 TVBox 配置，可多次指定")
    cli.add_argument("--inspect-tvbox", action="store_true", help="只检查导入结果，不启动服务")
    args = cli.parse_args()
    specs = json.loads(args.config.read_text(encoding="utf-8-sig"))
    ids = [spec["id"] for spec in specs]
    if len(ids) != len(set(ids)):
        cli.error("来源 ID 必须唯一")
    tvbox_specs = {}
    for url in args.tvbox:
        try:
            entries, skipped = read_subscription(url, fetch, media_url)
        except (OSError, ValueError) as error:
            print(f"TVBox 配置读取失败（{urlsplit(url).hostname}）：{error}", flush=True)
            continue
        print(f"TVBox：{len(entries)} 个可搜索 CMS 源，跳过类型及数量：{skipped}", flush=True)
        for entry in entries:
            tvbox_specs[entry["id"]] = entry
            print(f"  {entry['name']}（type {entry['cmsType']}）", flush=True)
    if args.inspect_tvbox:
        return 0 if tvbox_specs else 1
    specs.extend(entry for key, entry in tvbox_specs.items() if key not in ids)
    with ThreadingHTTPServer((args.host, args.port), Handler) as server:
        server.catalog = Catalog(specs)
        print(f"http://{args.host}:{server.server_port}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.catalog.pool.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
