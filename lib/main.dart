import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog.dart';
import 'player.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(QuickVideo(store: WatchStore(await SharedPreferences.getInstance())));
}

const appName = 'quick video';

class QuickVideo extends StatelessWidget {
  const QuickVideo({super.key, required this.store});

  final WatchStore store;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xffa7e3ba),
      brightness: Brightness.dark,
      surface: const Color(0xff131815),
    );
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colors,
        scaffoldBackgroundColor: colors.surface,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: colors.surfaceContainerHigh,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: LibraryPage(store: store),
    );
  }
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.store});

  final WatchStore store;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _query = TextEditingController();
  List<Work>? _results;
  List<String> _unavailable = [];
  String? _error;
  bool _searching = false;
  int _generation = 0;

  WatchStore get store => widget.store;

  Gateway? get _gateway {
    final address = store.server;
    return address == null ? null : Gateway(Uri.parse(address));
  }

  Future<void> _search(String text) async {
    final request = ++_generation;
    final query = text.trim();
    final gateway = _gateway;
    final results = <Work>[
      if (demo.title.contains(query)) demo,
    ];
    setState(() {
      _searching = gateway != null;
      _results = results;
      _unavailable = [];
      _error = null;
    });
    if (gateway == null) return;
    try {
      final result = await gateway.search(query);
      if (!mounted || request != _generation) return;
      setState(() {
        _results = [...results, ...result.works];
        _unavailable = result.unavailable;
        _searching = false;
      });
    } catch (error) {
      if (!mounted || request != _generation) return;
      setState(() {
        _error = errorMessage(error, '无法连接来源服务');
        _searching = false;
      });
    }
  }

  Future<void> _settings() async {
    final next = await showDialog<String>(
      context: context,
      builder: (_) => AddressDialog(previous: store.server, server: true),
    );
    if (next == null || !mounted) return;
    await store.setServer(next.isEmpty ? null : next);
    if (!mounted) return;
    setState(() {});
    if (_results != null || next.isNotEmpty) _search(_query.text);
  }

  Future<void> _direct() async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const AddressDialog(),
    );
    if (url == null || !mounted) return;
    final uri = Uri.parse(url);
    final label = uri.pathSegments.isEmpty || uri.pathSegments.last.isEmpty
        ? uri.host
        : uri.pathSegments.last;
    final line = Line('direct', url, '直链', url: url);
    final episode = Episode('main', '正片', [line]);
    await _play(_entry(jsonEncode(['direct', url]), label, episode, null));
  }

  WatchEntry _entry(String workId, String title, Episode episode, Gateway? gateway) {
    final previous = store.last(workId, episode.id);
    return WatchEntry(
      workId: workId, title: title, episode: episode,
      lineKey: previous?.lineKey ?? episode.lines.first.key,
      position: previous?.position ?? Duration.zero,
      gateway: gateway,
    );
  }

  Future<void> _play(WatchEntry entry) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlayerPage(entry: entry, store: store),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _detail(Work work) async {
    final gateway = identical(work, demo) ? null : _gateway;
    Future<List<Episode>> load() => gateway?.episodes(work) ??
        Future.value(work.episodes.values.toList());
    var episodes = load();
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        appBar: AppBar(title: const Text('视频详情')),
        body: SafeArea(
          child: StatefulBuilder(
            builder: (context, refresh) => FutureBuilder<List<Episode>>(
              future: episodes,
              builder: (context, snapshot) => ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(work.title, style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 8),
                  Text(work.subtitle),
                  const SizedBox(height: 28),
                  Text('选集', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  if (snapshot.connectionState != ConnectionState.done)
                    const LinearProgressIndicator()
                  else if (snapshot.hasError) ...[
                    Text(errorMessage(snapshot.error!, '无法读取剧集')),
                    TextButton(
                      onPressed: () => refresh(() => episodes = load()),
                      child: const Text('重试'),
                    ),
                  ] else if (snapshot.data!.isEmpty)
                    const Text('该来源没有提供可直接播放的 MP4 或 HLS 线路')
                  else
                    for (final episode in snapshot.data!)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.play_circle_outline),
                          title: Text(episode.name),
                          subtitle: Text('${episode.lines.length} 条播放线路'),
                          onTap: () {
                            final entry = _entry(work.id, work.title, episode, gateway);
                            Navigator.of(context).push(MaterialPageRoute<void>(
                              builder: (_) => PlayerPage(entry: entry, store: store),
                            ));
                          },
                        ),
                      ),
                ],
              ),
            ),
          ),
        ),
      ),
    ));
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Widget _workTile(Work work) => Card(
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      leading: const Icon(Icons.movie_outlined),
      title: Text(work.title),
      subtitle: Text(work.subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _detail(work),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final results = _results;
    return Scaffold(
      appBar: AppBar(
        title: const Text(appName, style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: '来源设置', icon: const Icon(Icons.tune),
            onPressed: _settings,
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
              children: [
                TextField(
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: '搜索片名',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: TextButton(onPressed: () => _search(_query.text), child: const Text('搜索')),
                  ),
                  onSubmitted: _search,
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _direct,
                    icon: const Icon(Icons.link),
                    label: const Text('打开视频链接'),
                  ),
                ),
                const SizedBox(height: 16),
                if (results == null) ...[
                  if (store.entries.isNotEmpty) ...[
                    Text('继续观看', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    for (final entry in store.entries)
                      Card(
                        child: ListTile(
                          title: Text(entry.title),
                          subtitle: Text('${entry.episode.name} · ${clock(entry.position)}'),
                          trailing: const Icon(Icons.play_arrow),
                          onTap: () => _play(entry),
                        ),
                      ),
                    const SizedBox(height: 20),
                  ],
                  _workTile(demo),
                ] else ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('搜索结果', style: Theme.of(context).textTheme.titleLarge),
                      TextButton(
                        onPressed: () => setState(() {
                          _generation++;
                          _query.clear();
                          _results = null;
                          _searching = false;
                        }),
                        child: const Text('回到首页'),
                      ),
                    ],
                  ),
                  if (_searching) const LinearProgressIndicator(),
                  if (_error != null) Text(_error!, style: TextStyle(color: colors.error)),
                  if (_unavailable.isNotEmpty)
                    Text('暂不可用的来源：${_unavailable.join('、')}'),
                  if (results.isEmpty && !_searching && _error == null)
                    const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Text('没有找到相关视频')),
                  for (final work in results) _workTile(work),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AddressDialog extends StatefulWidget {
  const AddressDialog({super.key, this.previous, this.server = false});

  final String? previous;
  final bool server;

  @override
  State<AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<AddressDialog> {
  late final _address = TextEditingController(text: widget.previous);
  bool _checking = false;
  String? _error;

  Future<void> _submit() async {
    if (_checking) return;
    final value = _address.text.trim();
    final uri = Uri.tryParse(value);
    if (uri == null || !validAddress(uri) || (widget.server && (uri.hasQuery || uri.hasFragment))) {
      setState(() => _error = '请输入有效的 HTTP 或 HTTPS 地址');
      return;
    }
    if (widget.server) {
      setState(() {
        _checking = true;
        _error = null;
      });
      try {
        await Gateway(uri).check();
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _checking = false;
          _error = errorMessage(error, '连接失败，请检查地址和服务状态');
        });
        return;
      }
    }
    if (mounted) Navigator.of(context).pop(uri.toString());
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.server ? '来源服务' : '打开视频链接'),
    content: TextField(
      controller: _address,
      autofocus: true,
      keyboardType: TextInputType.url,
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        hintText: widget.server ? 'http://127.0.0.1:8765' : 'https://…/video.m3u8',
        errorText: _error,
      ),
    ),
    actions: [
      if (widget.previous != null)
        TextButton(onPressed: _checking ? null : () => Navigator.of(context).pop(''), child: const Text('断开')),
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
      FilledButton(
        onPressed: _checking ? null : _submit,
        child: Text(_checking ? '连接中…' : widget.server ? '连接' : '播放'),
      ),
    ],
  );
}
