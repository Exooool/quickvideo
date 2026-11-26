"""Read TVBox subscriptions and query their direct CMS sources."""

import hashlib
import json
import re
import xml.etree.ElementTree as ET
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

# Preserve literal slashes inside strings while allowing comments and trailing commas.
JSON_EXTENSIONS = re.compile(r'"(?:\\.|[^"\\])*"|/\*[\s\S]*?\*/|//[^\r\n]*|,(?=\s*[}\]])')


def read_subscription(url, fetch, media_url):
    raw, base = fetch(url)
    if not raw.lstrip("\ufeff \t\r\n").startswith("{"):
        raise ValueError("接口返回的内容不是 TVBox JSON 对象")
    cleaned = JSON_EXTENSIONS.sub(
        lambda match: match[0] if match[0].startswith('"') else "", raw.lstrip("\ufeff"),
    )
    config = json.loads(JSON_EXTENSIONS.sub(
        lambda match: match[0] if match[0].startswith('"') else "", cleaned,
    ))
    if not isinstance(config.get("sites"), list):
        raise ValueError("TVBox 配置缺少 sites 数组")
    specs = {}
    skipped = {}
    for site in config["sites"]:
        if not isinstance(site, dict):
            continue
        kind = str(site.get("type", "未知"))
        if kind not in {"0", "1"} or str(site.get("searchable", 1)).lower() in {"0", "false"}:
            skipped[kind] = skipped.get(kind, 0) + 1
            continue
        try:
            api = media_url(site["api"].strip(), base)
        except (AttributeError, KeyError, ValueError):
            skipped[kind] = skipped.get(kind, 0) + 1
            continue
        key = str(site.get("key") or api)
        source_id = "tvbox-" + hashlib.sha256(f"{base}#{key}".encode()).hexdigest()[:24]
        specs[source_id] = {
            "id": source_id, "name": str(site.get("name") or key),
            "type": "tvbox-cms", "cmsType": kind, "url": api,
        }
    return list(specs.values()), skipped


def cms_url(spec, **query):
    parsed = urlsplit(spec["url"])
    params = dict(parse_qsl(parsed.query, keep_blank_values=True))
    params.update(query)
    return urlunsplit(parsed._replace(query=urlencode(params), fragment=""))


def read_cms(spec, fetch, **query):
    raw, base = fetch(cms_url(spec, **query))
    if raw.lstrip("\ufeff \t\r\n").startswith("<"):
        try:
            root = ET.fromstring(raw)
        except ET.ParseError as error:
            raise ValueError("CMS 返回无效 XML") from error
        if root.tag not in {"rss", "list"}:
            raise ValueError("CMS 返回的 XML 不是视频列表")
        rows = []
        for video in root.findall(".//video"):
            lines = video.findall("./dl/dd")
            rows.append({
                "vod_id": video.findtext("id"), "vod_name": video.findtext("name"),
                "vod_year": video.findtext("year"), "type_name": video.findtext("type"),
                "vod_play_from": "$$$".join(line.get("flag", "") for line in lines),
                "vod_play_url": "$$$".join(line.text or "" for line in lines),
            })
        return rows, base
    data = json.loads(raw)
    if not isinstance(data, dict) or not isinstance(data.get("list"), list):
        raise ValueError("CMS 返回的 JSON 缺少 list 数组")
    return [row for row in data["list"] if isinstance(row, dict)], base


def find_works(spec, query, fetch):
    if not query:
        return []
    rows, _ = read_cms(spec, fetch, ac="list", wd=query)
    return [
        {
            "id": str(row["vod_id"]), "sourceId": spec["id"], "sourceName": spec["name"],
            "title": str(row["vod_name"]), "year": str(row.get("vod_year") or ""),
            "kind": str(row.get("type_name") or "视频"),
            "workId": json.dumps([spec["id"], str(row["vod_id"])]), "needsDetail": True,
        }
        for row in rows[:30]
        if row.get("vod_id") is not None and row.get("vod_name")
    ]


def read_episodes(spec, work_id, fetch, media_url, stream_format):
    # XML CMS implementations commonly call the detail action videolist.
    action = "videolist" if spec["cmsType"] == "0" else "detail"
    rows, base = read_cms(spec, fetch, ac=action, ids=work_id)
    work = next((row for row in rows if str(row.get("vod_id")) == work_id), None)
    if not work:
        raise KeyError(work_id)
    names = str(work.get("vod_play_from") or "").split("$$$")
    groups = str(work.get("vod_play_url") or "").split("$$$")
    episodes = []
    seen = set()
    for index, group in enumerate(groups):
        label = names[index].strip() if index < len(names) else ""
        for entry in group.split("#"):
            entry = entry.strip()
            if not entry:
                continue
            name, separator, address = entry.partition("$")
            if not separator:
                name, address = "正片", name
            try:
                url = media_url(address.strip(), base)
            except ValueError:
                continue
            format_name = stream_format(url)
            if format_name == "auto":
                continue
            name = name.strip() or "正片"
            match = re.fullmatch(r"(?:第\s*)?(\d+)\s*(?:集|话|話)?", name)
            ep_id = f"episode-{int(match[1])}" if match else name
            line_id = json.dumps([work_id, index, ep_id], ensure_ascii=False, separators=(",", ":"))
            if line_id in seen:
                continue
            seen.add(line_id)
            episodes.append({
                "id": line_id, "sourceId": spec["id"], "sourceName": label or f"线路 {index + 1}",
                "episodeId": ep_id, "episode": name, "url": url, "format": format_name,
            })
    return episodes
