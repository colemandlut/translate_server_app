import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'models/recording.dart';
import 'models/transcript_entry.dart';
import 'services/recording_store.dart';

class RecordingDetailPage extends StatefulWidget {
  final String sessionId;
  const RecordingDetailPage({super.key, required this.sessionId});

  @override
  State<RecordingDetailPage> createState() => _RecordingDetailPageState();
}

class _RecordingDetailPageState extends State<RecordingDetailPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final _store = RecordingStore.instance;
  final _player = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _playing = false;
  bool _playerLoaded = false;
  String? _loadedPath;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _store.addListener(_rebuild);
    _posSub = _player.onPositionChanged.listen((d) {
      if (mounted) setState(() => _pos = d);
    });
    _durSub = _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _dur = d);
    });
    _stateSub = _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s == PlayerState.playing);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() {
        _playing = false;
        _pos = Duration.zero;
      });
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    _store.removeListener(_rebuild);
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _ensureLoaded(String path) async {
    if (_loadedPath == path && _playerLoaded) return;
    try {
      await _player.setSourceDeviceFile(path);
      _loadedPath = path;
      _playerLoaded = true;
    } catch (e) {
      _playerLoaded = false;
    }
  }

  Future<void> _togglePlay(String path) async {
    await _ensureLoaded(path);
    if (_playing) {
      await _player.pause();
    } else {
      await _player.resume();
    }
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  RecordingSession? _findSession() {
    for (final s in _store.sessions) {
      if (s.id == widget.sessionId) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final session = _findSession();
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16213e),
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFFe0e0ff)),
        title: Text(
          session != null ? _fmtDate(session.createdAt) : '录音',
          style: const TextStyle(color: Color(0xFFe0e0ff)),
        ),
        actions: [
          if (session != null)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Color(0xFFe74c3c)),
              onPressed: () => _confirmDelete(session),
            ),
        ],
        bottom: TabBar(
          controller: _tab,
          indicatorColor: const Color(0xFF53a8ff),
          labelColor: const Color(0xFFe0e0ff),
          unselectedLabelColor: const Color(0xFF7f8fa6),
          tabs: const [
            Tab(text: '实时'),
            Tab(text: '整段'),
            Tab(text: '总结'),
          ],
        ),
      ),
      body: session == null
          ? const Center(
              child: Text('录音不存在',
                  style: TextStyle(color: Color(0xFF7f8fa6))))
          : Column(
              children: [
                Expanded(
                  child: TabBarView(
                    controller: _tab,
                    children: [
                      _buildLiveTab(session),
                      _buildOverallTab(session),
                      _buildSummaryTab(session),
                    ],
                  ),
                ),
                _buildPlayerBar(session),
              ],
            ),
    );
  }

  Widget _buildLiveTab(RecordingSession s) {
    if (s.liveTranscripts.isEmpty) {
      return const Center(
        child: Text('(没有识别结果)',
            style: TextStyle(color: Color(0xFF7f8fa6))),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: s.liveTranscripts.length,
      itemBuilder: (_, i) => _buildEntry(s.liveTranscripts[i]),
    );
  }

  Widget _buildOverallTab(RecordingSession s) {
    if (s.overallText == null || s.overallText!.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '尚未对整段录音重新识别',
                style: TextStyle(color: Color(0xFF7f8fa6), fontSize: 14),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.cloud_upload),
                label: const Text('用 Dashscope 重做识别'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0f3460),
                  foregroundColor: const Color(0xFF53a8ff),
                ),
                onPressed: s.audioPath == null
                    ? null
                    : () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('整段重做识别功能将在下个版本上线'),
                          ),
                        );
                      },
              ),
              if (s.audioPath == null) ...[
                const SizedBox(height: 12),
                const Text(
                  '(此录音没有保存原始音频文件)',
                  style: TextStyle(color: Color(0xFF7f8fa6), fontSize: 11),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF16213e),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('原文',
                    style: TextStyle(
                        color: Color(0xFF7f8fa6),
                        fontSize: 11,
                        letterSpacing: 0.5)),
                const SizedBox(height: 4),
                Text(s.overallText!,
                    style: const TextStyle(
                        color: Color(0xFFe0e0ff), fontSize: 16, height: 1.5)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF0f3460),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('翻译',
                    style: TextStyle(
                        color: Color(0xFF7f8fa6),
                        fontSize: 11,
                        letterSpacing: 0.5)),
                const SizedBox(height: 4),
                Text(s.overallTranslated ?? '...',
                    style: const TextStyle(
                        color: Color(0xFF53a8ff), fontSize: 16, height: 1.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryTab(RecordingSession s) {
    if (s.llmSummary == null || s.llmSummary!.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'LLM 总结功能开发中（TODO）',
            style: TextStyle(color: Color(0xFF7f8fa6), fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Text(
        s.llmSummary!,
        style: const TextStyle(
            color: Color(0xFFe0e0ff), fontSize: 15, height: 1.6),
      ),
    );
  }

  Widget _buildPlayerBar(RecordingSession s) {
    final path = s.audioPath;
    final hasAudio = path != null && File(path).existsSync();
    final total = _dur.inMilliseconds > 0 ? _dur : s.duration;
    final progress = total.inMilliseconds == 0
        ? 0.0
        : (_pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      decoration: const BoxDecoration(
        color: Color(0xFF16213e),
        border: Border(top: BorderSide(color: Color(0xFF0f3460), width: 1)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              _playing ? Icons.pause : Icons.play_arrow,
              color: hasAudio ? const Color(0xFF53a8ff) : const Color(0xFF7f8fa6),
              size: 32,
            ),
            onPressed: hasAudio ? () => _togglePlay(path) : null,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                  ),
                  child: Slider(
                    value: progress.toDouble(),
                    onChanged: hasAudio
                        ? (v) async {
                            final ms = (v * total.inMilliseconds).round();
                            await _ensureLoaded(path);
                            await _player.seek(Duration(milliseconds: ms));
                          }
                        : null,
                    activeColor: const Color(0xFF53a8ff),
                    inactiveColor: const Color(0xFF0f3460),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    hasAudio
                        ? '${_fmtDuration(_pos)} / ${_fmtDuration(total)}'
                        : '(此录音没有保存原始音频)',
                    style: const TextStyle(
                        color: Color(0xFF7f8fa6), fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEntry(TranscriptEntry e) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            color: const Color(0xFF16213e),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.spokenLang,
                    style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF7f8fa6),
                        letterSpacing: 0.5)),
                const SizedBox(height: 4),
                Text(e.original,
                    style: const TextStyle(
                        fontSize: 16, color: Color(0xFFe0e0ff), height: 1.5)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(14),
            color: const Color(0xFF0f3460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.translatedLang,
                    style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF7f8fa6),
                        letterSpacing: 0.5)),
                const SizedBox(height: 4),
                Text(e.translated,
                    style: const TextStyle(
                        fontSize: 16, color: Color(0xFF53a8ff), height: 1.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmtDate(DateTime d) {
    final two = (int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  String _fmtDuration(Duration d) {
    final s = d.inSeconds;
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  void _confirmDelete(RecordingSession s) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF16213e),
        title: const Text('删除录音?',
            style: TextStyle(color: Color(0xFFe0e0ff))),
        content: const Text('删除后无法恢复',
            style: TextStyle(color: Color(0xFF7f8fa6))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _store.remove(s.id);
              if (mounted) Navigator.pop(context);
            },
            child: const Text('删除',
                style: TextStyle(color: Color(0xFFe74c3c))),
          ),
        ],
      ),
    );
  }
}
