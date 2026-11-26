import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'catalog.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.entry, required this.store});

  final WatchEntry entry;
  final WatchStore store;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  late Line _selected;
  late Duration _position;
  bool _loading = true;
  String? _error;
  bool _active = true;
  Timer? _checkpoint;

  WatchEntry get entry => widget.entry;
  List<Line> get lines => entry.episode.lines;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selected = lines.firstWhere((line) => line.key == entry.lineKey, orElse: () => lines.first);
    _position = entry.position;
    _checkpoint = Timer.periodic(const Duration(seconds: 3), (_) => _save());
    _open(_selected, initial: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (!_active) {
      _save();
      _controller?.pause();
    }
  }

  void _save() {
    final value = _controller?.value;
    if (value == null || !value.isInitialized || value.hasError || _loading) return;
    _position = value.isCompleted ? Duration.zero : value.position;
    widget.store.save(WatchEntry(
      workId: entry.workId, title: entry.title, episode: entry.episode,
      lineKey: _selected.key, position: _position, gateway: entry.gateway,
    ));
  }

  Future<Playback> _resolve(Line line) async {
    if (line.asset != null) return Playback(asset: line.asset);
    final gateway = entry.gateway;
    if (gateway is TvboxGateway) return gateway.resolve(line);
    if (line.url != null) {
      final uri = Uri.parse(line.url!);
      return Playback(uri: uri, format: uri.path.toLowerCase().endsWith('.m3u8') ? 'hls' : null);
    }
    return entry.gateway!.resolve(line);
  }

  Future<void> _open(Line selected, {bool initial = false}) async {
    if (!initial && _loading) return;
    _save();
    final previous = _controller;
    setState(() {
      _controller = null;
      _loading = true;
      _error = null;
    });
    await previous?.dispose();
    if (!mounted) return;
    final choices = [selected, if (initial) ...lines.where((line) => line != selected)];
    for (final line in choices) {
      VideoPlayerController? candidate;
      try {
        final media = await _resolve(line);
        if (!mounted) return;
        final asset = media.asset;
        final next = asset != null
            ? VideoPlayerController.asset(asset)
            : VideoPlayerController.networkUrl(
                media.uri!,
                formatHint: media.format == 'hls' ? VideoFormat.hls : null,
              );
        candidate = next;
        await next.initialize().timeout(const Duration(seconds: 12));
        if (!mounted) {
          await next.dispose();
          return;
        }
        if (_position > Duration.zero && _position < next.value.duration) {
          await next.seekTo(_position);
        }
        if (_active && mounted) await next.play();
        if (!mounted) {
          await next.dispose();
          return;
        }
        setState(() {
          _controller = next;
          _selected = line;
          _loading = false;
        });
        return;
      } catch (error) {
        await candidate?.dispose();
        if (!mounted) return;
        _error = errorMessage(error, '当前线路播放失败，请重试或切换线路');
      }
    }
    if (mounted) setState(() {
      _selected = selected;
      _loading = false;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _checkpoint?.cancel();
    _save();
    _controller?.dispose();
    super.dispose();
  }

  Widget _retry(String message) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(message, textAlign: TextAlign.center),
      const SizedBox(height: 8),
      TextButton(onPressed: () => _open(_selected), child: const Text('重试')),
    ],
  );

  Widget _screen() {
    final controller = _controller;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (controller == null) return Center(child: _retry(_error ?? '视频无法播放'));
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (context, value, child) {
        if (value.hasError) return Center(child: _retry('播放中断，请重试或切换线路'));
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _toggle(controller),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(child: AspectRatio(
                aspectRatio: value.aspectRatio,
                child: VideoPlayer(controller),
              )),
              if (value.isBuffering)
                const Center(child: CircularProgressIndicator())
              else if (!value.isPlaying)
                const Center(child: Icon(Icons.play_circle_fill, size: 56, color: Colors.white)),
            ],
          ),
        );
      },
    );
  }

  Future<void> _toggle(VideoPlayerController controller) async {
    if (controller.value.isPlaying) {
      await controller.pause();
      _save();
    } else {
      if (controller.value.isCompleted) await controller.seekTo(Duration.zero);
      await controller.play();
    }
  }

  Widget _controls(VideoPlayerController controller) => ValueListenableBuilder(
    valueListenable: controller,
    builder: (context, value, child) {
      if (value.hasError) return const SizedBox.shrink();
      return Column(children: [
        VideoProgressIndicator(
          controller, allowScrubbing: true,
          colors: VideoProgressColors(
            playedColor: Theme.of(context).colorScheme.primary,
            bufferedColor: Colors.white38,
            backgroundColor: Colors.white12,
          ),
        ),
        Row(children: [
          IconButton(
            onPressed: () => _toggle(controller),
            tooltip: value.isPlaying ? '暂停' : '播放',
            icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
          ),
          Text('${clock(value.position)} / ${clock(value.duration)}'),
        ]),
      ]);
    },
  );

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(title: Text(entry.title)),
      body: SafeArea(
        child: ListView(
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ColoredBox(color: Colors.black, child: _screen()),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (controller != null) _controls(controller),
                  const SizedBox(height: 12),
                  Text(entry.episode.name, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 20),
                  Text('播放线路', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final line in lines)
                        ChoiceChip(
                          label: Text(line.name),
                          selected: line == _selected,
                          onSelected: _loading ? null : (chosen) {
                            if (chosen) _open(line);
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
