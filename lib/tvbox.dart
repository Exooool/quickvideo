part of 'catalog.dart';

class TvboxGateway extends Gateway {
  TvboxGateway(super.base, {this.plugin, this.cspSite});

  final CspPlugin? plugin;
  final String? cspSite;
  final Map<String, String> cspChoices = {};
  List<String> _flags = [];

  static final _jsonTokens = RegExp(r'"(?:\\.|[^"\\])*"|/\*[\s\S]*?\*/|//[^\r\n]*|,(?=\s*[}\]])');
  static final _episodeNumber = RegExp(r'^(?:第\s*)?(\d+)\s*(?:集|话|話)?$');
  Map<String, _CmsSite>? _sites;

  @override
  String get kind => 'tvbox';

  static bool supports(Uri? uri) => validAddress(uri) && uri!.scheme == 'https';

  @override
  Future<void> check() async {
    _sites = await _loadSites();
  }

  Future<Map<String, _CmsSite>> _loadSites() async {
    final payload = await _download(base);
    final text = payload.text.trimLeft();
    if (!text.startsWith('{')) {
      throw const FormatException('该地址没有返回 TVBox JSON 配置');
    }
    String stripExtensions(String value) => value.replaceAllMapped(
      _jsonTokens,
      (match) => match[0]!.startsWith('"') ? match[0]! : '',
    );
    final tree = _json(stripExtensions(stripExtensions(text)), '订阅 JSON 格式错误');
    if (tree is! Json || tree['sites'] is! List) {
      throw const FormatException('订阅配置缺少 sites 列表');
    }
    final entries = (tree['sites'] as List).whereType<Json>().toList();
    if (entries.isEmpty) throw const FormatException('订阅的点播来源列表为空');
    final sites = <String, _CmsSite>{};
    final cspSites = <String, _CmsSite>{};
    var plugins = 0;
    var httpCms = 0;
    var disabled = 0;
    var unsupported = 0;
    final baseSpider = tree['spider'];
    final flags = tree['flags'];
    _flags = flags is List ? flags.whereType<String>().toList() : [];
    final installed = Platform.isAndroid ? plugin : null;
    final cspClass = RegExp(r'^csp_[A-Za-z_$][A-Za-z0-9_$]{0,127}$');
    for (final entry in entries) {
      final type = entry['type']?.toString();
      final searchable = entry['searchable']?.toString().toLowerCase();
      final canSearch = searchable != '0' && searchable != 'false';
      final api = entry['api'];
      if (type == '3' && api is String && cspClass.hasMatch(api.trim())) {
        plugins++;
        final declared = entry['jar'] ?? baseSpider;
        final fingerprint = declared is String
            ? RegExp(r';md5;([0-9a-fA-F]{32})\s*$').firstMatch(declared)?[1]?.toLowerCase()
            : null;
        if (canSearch && installed != null && fingerprint == installed.md5) {
          final id = entry['key']?.toString().trim() ?? api.trim();
          final ext = entry['ext'];
          cspSites[id] = _CmsSite(id, entry['name']?.toString() ?? id, payload.uri, false,
            cspApi: api.trim(), ext: ext is String ? ext : ext == null ? '' : jsonEncode(ext),
          );
        }
        continue;
      }
      if (!canSearch) {
        disabled++;
        continue;
      }
      if ((type != '0' && type != '1') || api is! String) {
        unsupported++;
        continue;
      }
      final url = _resolveUri(payload.uri, api);
      if (!supports(url)) {
        if (url?.scheme == 'http') {
          httpCms++;
        } else {
          unsupported++;
        }
        continue;
      }
      final key = entry['key']?.toString().trim();
      final id = key == null || key.isEmpty ? url.toString() : key;
      sites[id] = _CmsSite(id, entry['name']?.toString() ?? id, url!, type == '0');
    }
    cspChoices
      ..clear()
      ..addEntries(cspSites.entries.map((entry) => MapEntry(entry.key, entry.value.name)));
    if (cspSites.isNotEmpty) {
      await installed!.check();
      final chosen = cspSites[cspSite];
      if (chosen != null) {
        sites[chosen.id] = chosen;
      } else if (cspSite != null) {
        throw const FormatException('订阅中已找不到所选 CSP 来源，请重新选择');
      }
    } else if (cspSite != null) {
      throw const FormatException('订阅已换插件或本地插件已移除，请重新导入并选择 CSP 来源');
    }
    if (sites.isEmpty && cspChoices.isEmpty) {
      final counts = [
        if (plugins > 0)
          installed == null
              ? '$plugins 个 CSP 来源。请先从来源设置导入该订阅对应的本地插件'
              : '$plugins 个 CSP 来源与已导入插件不匹配，请检查订阅的插件版本',
        if (httpCms > 0) '$httpCms 个 HTTP CMS 源（手机直连需要 HTTPS）',
        if (disabled > 0) '$disabled 个未开启搜索的来源',
        if (unsupported > 0) '$unsupported 个其他不兼容的来源',
      ];
      throw FormatException(
        '已读取 ${entries.length} 个点播来源，当前没有可用来源。'
        '\n${counts.join('。')}。',
      );
    }
    return sites;
  }

  Future<Map<String, _CmsSite>> _getSites() async => _sites ??= await _loadSites();

  @override
  Future<SearchResult> search(String query) async {
    if (query.isEmpty) return const SearchResult([], []);
    final sites = (await _getSites()).values.toList();
    final answers = List<List<Work>?>.filled(sites.length, null);
    var nextIndex = 0;
    var accepting = true;
    Exception? onlySourceError;

    Future<void> worker() async {
      while (accepting && nextIndex < sites.length) {
        final index = nextIndex++;
        final site = sites[index];
        try {
          final payload = await _cms(site, {'ac': 'list', 'wd': query});
          answers[index] = [
            for (final row in payload.rows.take(30))
              if (row['vod_id'] != null && (row['vod_name']?.toString().trim().isNotEmpty ?? false))
                Work(
                  jsonEncode([kind, base.toString(), site.id, row['vod_id'].toString()]),
                  row['vod_name'].toString(),
                  [row['vod_year'], row['type_name'], site.name]
                      .where((value) => value?.toString().isNotEmpty ?? false)
                      .join(' · '),
                  remote: Line(site.id, row['vod_id'].toString(), site.name),
                ),
          ];
        } on Exception catch (error) {
          if (site.cspApi != null && sites.length == 1) onlySourceError = error;
          // Report this source separately so other sources remain searchable.
        }
      }
    }

    try {
      await Future.wait([
        for (var i = 0; i < 8 && i < sites.length; i++) worker(),
      ]).timeout(const Duration(seconds: 12));
    } on TimeoutException {
      // Retain results received within the search deadline.
    } finally {
      accepting = false;
    }
    if (onlySourceError != null) throw onlySourceError!;
    return SearchResult(
      [for (final answer in answers) ...?answer],
      [for (var i = 0; i < sites.length; i++) if (answers[i] == null) sites[i].name],
    );
  }

  @override
  Future<List<Episode>> episodes(Work work) async {
    final remote = work.remote;
    if (remote == null) return work.episodes.values.toList();
    return _episodesFor(remote.source, remote.id);
  }

  Future<List<Episode>> _episodesFor(String sourceId, String workId) async {
    final site = (await _getSites())[sourceId];
    if (site == null) throw const FormatException('订阅里已找不到这个来源');
    final data = await _cms(site, {'ac': site.xml ? 'videolist' : 'detail', 'ids': workId});
    final matching = data.rows.where((item) => item['vod_id']?.toString() == workId);
    if (matching.isEmpty) throw const FormatException('来源没有返回这部作品的详情');
    final row = matching.first;
    final groups = (row['vod_play_url']?.toString() ?? '').split(r'$$$');
    final labels = (row['vod_play_from']?.toString() ?? '').split(r'$$$');
    final episodes = <String, Episode>{};
    final seen = <String>{};
    for (var index = 0; index < groups.length; index++) {
      final label = index < labels.length ? labels[index].trim() : '';
      for (final item in groups[index].split('#')) {
        final separator = item.indexOf(r'$');
        final address = separator < 0 ? item : item.substring(separator + 1);
        if (address.trim().isEmpty) continue;
        final uri = site.cspApi == null ? _resolveUri(data.uri, address) : null;
        if (site.cspApi == null && (!supports(uri) || _format(uri!) == null)) continue;
        final name = separator < 0 ? '' : item.substring(0, separator).trim();
        final episodeName = name.isEmpty ? '正片' : name;
        final digits = _episodeNumber.firstMatch(episodeName)?[1];
        final number = digits == null ? null : int.tryParse(digits);
        final episodeId = number == null ? episodeName : 'episode-$number';
        final lineId = jsonEncode([workId, index, episodeId]);
        if (!seen.add(lineId)) continue;
        final episode = episodes.putIfAbsent(
          episodeId, () => Episode(episodeId, episodeName, []),
        );
        episode.lines.add(Line(site.id, lineId, label.isEmpty ? '线路 ${index + 1}' : label,
          url: site.cspApi == null ? uri!.toString() : jsonEncode([label, address.trim()]),
        ));
      }
    }
    return episodes.values.toList();
  }

  @override
  Future<Playback> resolve(Line line) async {
    final id = jsonDecode(line.id) as List<dynamic>;
    final episodes = await _episodesFor(line.source, id.first as String);
    for (final episode in episodes) {
      for (final current in episode.lines) {
        if (current.id != line.id) continue;
        final site = (await _getSites())[line.source];
        if (site != null && site.cspApi != null) {
          final request = (jsonDecode(current.url!) as List).cast<String>();
          final result = await plugin!.invoke(site, 'play', {
            'flag': request[0], 'id': request[1], 'flags': _flags,
          });
          final playUrl = result['url'];
          final uri = playUrl is String ? Uri.tryParse(playUrl) : null;
          final parse = result['parse']?.toString();
          final separate = result['jx']?.toString();
          if (!supports(uri) ||
              (parse != null && parse != '0' && parse != 'false') ||
              (separate != null && separate != '0' && separate != 'false')) {
            throw const FormatException('CSP 未返回可直连的 HTTPS 视频，网页解析和本地代理暂不可用');
          }
          final rawHeaders = result['header'];
          final headerValues = rawHeaders is String
              ? _json(rawHeaders, 'CSP 播放请求头格式无效')
              : rawHeaders;
          final headers = <String, String>{};
          if (headerValues is Map) {
            for (final item in headerValues.entries) {
              if (item.key is String && item.value is String) {
                headers[item.key as String] = item.value as String;
              }
            }
          }
          final type = result['type']?.toString().toLowerCase() ?? '';
          return Playback(
            uri: uri, headers: headers,
            format: type.contains('mpegurl') || type == 'm3u8' ? 'hls' : _format(uri!),
          );
        }
        final uri = Uri.parse(current.url!);
        return Playback(uri: uri, format: _format(uri));
      }
    }
    throw const FormatException('这条播放线路已不可用');
  }

  static String? _format(Uri uri) {
    final path = uri.path.toLowerCase();
    if (path.endsWith('.m3u8')) return 'hls';
    if (path.endsWith('.mp4')) return 'mp4';
    return null;
  }

  static Uri? _resolveUri(Uri base, String value) {
    if (value.trim().isEmpty) return null;
    try {
      return base.resolve(value.trim());
    } on FormatException {
      return null;
    }
  }

  static Object? _json(String text, String error) {
    try {
      return jsonDecode(text);
    } on FormatException {
      throw FormatException(error);
    }
  }

  Future<({List<Json> rows, Uri uri})> _cms(
    _CmsSite site, Map<String, String> query,
  ) async {
    if (site.cspApi != null) {
      final keyword = query['wd'];
      final payload = keyword == null
          ? await plugin!.invoke(site, 'detail', {'id': query['ids']})
          : await plugin!.invoke(site, 'search', {'query': keyword});
      if (payload['list'] is! List) {
        throw const FormatException('CSP 插件没有返回视频列表');
      }
      return (rows: (payload['list'] as List).whereType<Json>().toList(), uri: site.url);
    }
    final uri = site.url.replace(
      queryParameters: {...site.url.queryParametersAll, ...query},
      fragment: '',
    );
    final payload = await _download(uri);
    if (payload.text.trimLeft().startsWith('<')) {
      try {
        final root = XmlDocument.parse(payload.text).rootElement;
        if (root.name.local != 'rss' && root.name.local != 'list') {
          throw const FormatException('CMS 没有返回 XML 视频列表');
        }
        return (
          rows: [for (final video in root.findAllElements('video')) _xmlVideo(video)],
          uri: payload.uri,
        );
      } on XmlException {
        throw const FormatException('CMS 返回了无效的 XML');
      }
    }
    final response = _json(payload.text, 'CMS 返回了无效的 JSON');
    if (response is! Json || response['list'] is! List) {
      throw const FormatException('CMS 没有返回视频列表');
    }
    return (rows: (response['list'] as List).whereType<Json>().toList(), uri: payload.uri);
  }

  static Json _xmlVideo(XmlElement video) {
    final lines = video.findElements('dl').expand((item) => item.findElements('dd')).toList();
    String? field(String name) => video.getElement(name)?.innerText;
    return {
      'vod_id': field('id'),
      'vod_name': field('name'),
      'vod_year': field('year'),
      'type_name': field('type'),
      'vod_play_from': lines.map((line) => line.getAttribute('flag') ?? '').join(r'$$$'),
      'vod_play_url': lines.map((line) => line.innerText).join(r'$$$'),
    };
  }

  static Future<({String text, Uri uri})> _download(Uri initial) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      return await (() async {
        var uri = initial;
        for (var redirects = 0; redirects <= 4; redirects++) {
          if (!supports(uri)) throw const FormatException('订阅和 CMS 地址需要使用 HTTPS');
          final request = await client.getUrl(uri);
          request.followRedirects = false;
          final response = await request.close();
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (response.isRedirect && location != null) {
            uri = _resolveUri(uri, location) ?? (throw const FormatException('无效的跳转地址'));
            await response.drain<void>();
            continue;
          }
          if (response.statusCode != HttpStatus.ok) {
            throw FormatException('来源返回 HTTP ${response.statusCode}');
          }
          final bytes = <int>[];
          await for (final chunk in response) {
            if (bytes.length + chunk.length > 3 * 1024 * 1024) {
              throw const FormatException('来源响应超过 3 MB');
            }
            bytes.addAll(chunk);
          }
          final text = utf8.decode(bytes).replaceFirst(RegExp(r'^\uFEFF'), '');
          if (text.trim().isEmpty) throw const FormatException('来源返回了空内容');
          return (text: text, uri: uri);
        }
        throw const FormatException('来源跳转次数过多');
      })().timeout(const Duration(seconds: 6));
    } on TimeoutException {
      throw const FormatException('来源请求超时');
    } finally {
      client.close(force: true);
    }
  }
}

class _CmsSite {
  const _CmsSite(this.id, this.name, this.url, this.xml, {this.cspApi, this.ext = ''});

  final String id;
  final String name;
  final Uri url;
  final bool xml;
  final String? cspApi;
  final String ext;
}
