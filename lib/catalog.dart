import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

typedef Json = Map<String, dynamic>;

class Line {
  const Line(this.source, this.id, this.name, {this.asset, this.url});

  final String source;
  final String id;
  final String name;
  final String? asset;
  final String? url;

  String get key => jsonEncode([source, id]);

  factory Line.fromJson(Json data) => Line(
    data['sourceId'] as String,
    data['id'] as String,
    data['sourceName'] as String,
    asset: data['asset'] as String?,
    url: data['url'] as String?,
  );

  Json toJson() => {
    'sourceId': source, 'id': id, 'sourceName': name, 'asset': asset, 'url': url,
  };
}

class Episode {
  Episode(this.id, this.name, this.lines);

  final String id;
  final String name;
  final List<Line> lines;
}

class Work {
  Work(this.id, this.title, this.subtitle, {this.remote});

  final String id;
  final String title;
  final String subtitle;
  final Line? remote;
  final Map<String, Episode> episodes = {};
}

final demo = Work('bundled-demo', '播放测试片', '测试视频')..episodes['1'] = Episode(
  '1', '第 1 集', const [
    Line('local-a', '1', '样例 · 高清', asset: 'assets/demo.mp4'),
    Line('local-b', '1', '样例 · 流畅', asset: 'assets/demo_alt.mp4'),
  ],
);

class Playback {
  const Playback({this.asset, this.uri, this.format});

  final String? asset;
  final Uri? uri;
  final String? format;
}

class SearchResult {
  const SearchResult(this.works, this.unavailable);

  final List<Work> works;
  final List<String> unavailable;
}

bool validAddress(Uri? uri) => uri != null &&
    (uri.scheme == 'http' || uri.scheme == 'https') &&
    uri.host.isNotEmpty && uri.userInfo.isEmpty;

class Gateway {
  const Gateway(this.base);

  final Uri base;

  Uri _route(String path, [Map<String, String>? query]) => base.replace(
    path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}/$path',
    queryParameters: query,
  );

  Future<Json> _get(String path, [Map<String, String>? query]) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      return await (() async {
        final response = await (await client.getUrl(_route(path, query))).close();
        final body = await response.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Json;
        if (response.statusCode != 200) {
          throw FormatException(data['error'] as String? ?? '来源服务请求失败');
        }
        return data;
      })().timeout(const Duration(seconds: 8));
    } finally {
      client.close(force: true);
    }
  }

  Future<void> check() async {
    if ((await _get('health'))['ok'] != true) {
      throw const FormatException('这个地址没有提供视频来源服务');
    }
  }

  Future<SearchResult> search(String query) async {
    final data = await _get('search', {'q': query});
    final works = <String, Work>{};
    for (final item in (data['items'] as List).cast<Json>()) {
      final title = item['title'] as String;
      final kind = item['kind'] as String;
      final year = item['year'] as String;
      final workId = item['workId'] as String?;
      final line = Line.fromJson(item);
      final key = jsonEncode([
        base.toString(),
        if (workId != null && workId.isNotEmpty) ...['work', workId]
        else ...[
          if (year.isEmpty) line.source,
          title.trim().toLowerCase(), year, kind,
        ],
      ]);
      final remote = item['needsDetail'] == true;
      final work = works.putIfAbsent(key, () => Work(
        key,
        title,
        [if (year.isNotEmpty) year, kind, if (remote) line.name].join(' · '),
        remote: remote ? line : null,
      ));
      if (!remote) _addEpisode(work.episodes, item, line);
    }
    return SearchResult(works.values.toList(), (data['unavailable'] as List).cast<String>());
  }

  void _addEpisode(Map<String, Episode> episodes, Json data, Line line) {
    final id = data['episodeId'] as String;
    final episode = episodes.putIfAbsent(id, () => Episode(
      id, data['episode'] as String, [],
    ));
    episode.lines.add(line);
  }

  Future<List<Episode>> episodes(Work work) async {
    final remote = work.remote;
    if (remote == null) return work.episodes.values.toList();
    final data = await _get('detail', {'source': remote.source, 'id': remote.id});
    final episodes = <String, Episode>{};
    for (final item in (data['items'] as List).cast<Json>()) {
      _addEpisode(episodes, item, Line.fromJson(item));
    }
    return episodes.values.toList();
  }

  Future<Playback> resolve(Line line) async {
    final data = await _get('resolve', {'source': line.source, 'id': line.id});
    final assetPath = data['assetPath'] as String?;
    final uri = assetPath == null
        ? Uri.tryParse(data['url'] as String? ?? '')
        : _route(assetPath.substring(1));
    if (!validAddress(uri)) throw const FormatException('无效的播放地址');
    return Playback(uri: uri, format: data['format'] as String?);
  }
}

class WatchEntry {
  const WatchEntry({
    required this.workId, required this.title, required this.episode,
    required this.lineKey, required this.position, required this.gateway,
  });

  final String workId;
  final String title;
  final Episode episode;
  final String lineKey;
  final Duration position;
  final Gateway? gateway;

  String get key => jsonEncode([workId, episode.id]);

  factory WatchEntry.fromJson(Json data) {
    final base = data['gateway'] as String?;
    return WatchEntry(
      workId: data['workId'] as String, title: data['title'] as String,
      episode: Episode(
        data['episodeId'] as String, data['episode'] as String,
        (data['lines'] as List).cast<Json>().map(Line.fromJson).toList(),
      ),
      lineKey: data['lineKey'] as String,
      position: Duration(milliseconds: data['position'] as int),
      gateway: base == null ? null : Gateway(Uri.parse(base)),
    );
  }

  Json toJson() => {
    'workId': workId, 'title': title, 'episodeId': episode.id,
    'episode': episode.name, 'lines': episode.lines.map((line) => line.toJson()).toList(),
    'lineKey': lineKey, 'position': position.inMilliseconds, 'gateway': gateway?.base.toString(),
  };
}

class WatchStore {
  WatchStore(this.prefs)
      : entries = (prefs.getStringList('watch') ?? []).map(
          (entry) => WatchEntry.fromJson(jsonDecode(entry) as Json),
        ).toList();

  final SharedPreferences prefs;
  final List<WatchEntry> entries;

  String? get server => prefs.getString('gateway');

  Future<void> setServer(String? address) async {
    if (address == null) {
      await prefs.remove('gateway');
    } else {
      await prefs.setString('gateway', address);
    }
  }

  WatchEntry? last(String workId, String episodeId) {
    for (final entry in entries) {
      if (entry.workId == workId && entry.episode.id == episodeId) return entry;
    }
    return null;
  }

  void save(WatchEntry entry) {
    entries.removeWhere((old) => old.key == entry.key);
    entries.insert(0, entry);
    if (entries.length > 30) entries.removeLast();
    prefs.setStringList('watch', entries.map((item) => jsonEncode(item.toJson())).toList());
  }
}

String clock(Duration value) {
  final minute = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final second = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return value.inHours > 0 ? '${value.inHours}:$minute:$second' : '$minute:$second';
}

String errorMessage(Object error, String fallback) =>
    error is FormatException ? error.message : fallback;
