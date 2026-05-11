import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'models/recording.dart';
import 'models/transcript_entry.dart';
import 'models/transcript_segment.dart';
import 'services/recording_store.dart';
import 'services/file_recognize_client.dart';
import 'services/audio_path_resolver.dart';

class RecordingDetailPage extends StatefulWidget {
  final String sessionId;
  const RecordingDetailPage({super.key, required this.sessionId});

  @override
  State<RecordingDetailPage> createState() => _RecordingDetailPageState();
}

class _RecordingDetailPageState extends State<RecordingDetailPage>
    with TickerProviderStateMixin {
  late final TabController _tab;
  // 平滑播放位置：audioplayers 的 onPositionChanged 在 iOS 上约 200ms 才回
  // 一次，逐字渐变会肉眼可见地"卡"。用 Ticker 在两次真实回调之间用 wall clock
  // 推算 smooth 位置，每帧 ~16ms 重新计算字内 lerp。
  late final Ticker _smoothTicker;
  int _authMs = 0; // 最近一次 audioplayers 返回的位置（ms）
  DateTime _authAt = DateTime.now();
  // 用户拖动 slider 时的临时值（0~1）。非 null 表示正在拖动，slider 显示用它
  // 而不是 progress——避免拖动期间 _pos 还没 seek 完导致 slider 回弹。
  double? _dragValue;
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

  // 整段重识别状态
  bool _reasrInflight = false;
  String? _reasrError;

  // 字幕跟随播放：当前激活的 segment 索引（按播放位置算）；GlobalKey list
  // 用于自动滚动到激活卡片。
  int _activeSegIdx = -1;
  final List<GlobalKey> _segKeys = [];

  // 音频路径解析缓存：session.audioPath 现在存的是相对路径
  // （`recordings/xxx.m4a`），用前需 resolve 成绝对路径。
  String? _lastSeenAudioPath;
  String? _resolvedAudioPath;
  bool _audioResolved = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _store.addListener(_rebuild);
    _posSub = _player.onPositionChanged.listen(_onPositionTick);
    _durSub = _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _dur = d);
    });
    _stateSub = _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s == PlayerState.playing);
    });
    _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _playing = false;
        _pos = Duration.zero;
        _authMs = 0;
        _authAt = DateTime.now();
        _activeSegIdx = -1;
      });
      // 不需要在这里 seek/stop——下次按播放走 play(source, position: 0)
      // 会重新装载并从头播。
    });
    _smoothTicker = createTicker(_onSmoothTick)..start();
  }

  void _onSmoothTick(Duration _) {
    if (!_playing || !mounted) return;
    final delta = DateTime.now().difference(_authAt).inMilliseconds;
    final smoothMs = _authMs + delta;
    if (smoothMs == _pos.inMilliseconds) return;
    setState(() {
      _pos = Duration(milliseconds: smoothMs);
    });
    _updateActiveSegIfNeeded();
  }

  void _updateActiveSegIfNeeded() {
    final s = _findSession();
    final segs = s?.overallSegments;
    if (segs == null || segs.isEmpty) return;
    final ms = _pos.inMilliseconds;
    int newIdx = -1;
    for (int i = 0; i < segs.length; i++) {
      final b = segs[i].beginMs;
      if (b == null) continue;
      if (b <= ms) {
        newIdx = i;
      } else {
        break;
      }
    }
    if (newIdx != _activeSegIdx) {
      setState(() => _activeSegIdx = newIdx);
      if (newIdx >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (newIdx >= _segKeys.length) return;
          final ctx = _segKeys[newIdx].currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(
              ctx,
              duration: const Duration(milliseconds: 250),
              alignment: 0.3,
            );
          }
        });
      }
    }
  }

  // audioplayers 给的真实位置回调：把它当作"权威采样点"，记录时间戳，让 Ticker
  // 在两次回调之间插值。
  void _onPositionTick(Duration d) {
    if (!mounted) return;
    _authMs = d.inMilliseconds;
    _authAt = DateTime.now();
    setState(() {
      _pos = d;
    });
    _updateActiveSegIfNeeded();
  }

  GlobalKey _keyForSeg(int i) {
    while (_segKeys.length <= i) {
      _segKeys.add(GlobalKey());
    }
    return _segKeys[i];
  }

  @override
  void dispose() {
    _smoothTicker.dispose();
    _tab.dispose();
    _store.removeListener(_rebuild);
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay(String path) async {
    if (_playing) {
      await _player.pause();
      return;
    }
    // 用 play(source, position: ...) 而不是 resume()——后者在 stopped/completed
    // state 下在 iOS audioplayers 上不可靠（拖动后/播完后没声音）。play() 内部
    // setSource + seek + start，状态机不管之前是啥都能正确播。
    final durMs = _dur.inMilliseconds;
    final atEnd = durMs > 0 && _pos.inMilliseconds >= durMs - 200;
    final startPos = atEnd ? Duration.zero : _pos;
    if (atEnd) {
      setState(() {
        _pos = Duration.zero;
        _authMs = 0;
        _authAt = DateTime.now();
        _activeSegIdx = -1;
      });
    }
    await _player.play(DeviceFileSource(path), position: startPos);
    _loadedPath = path;
    _playerLoaded = true;
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

  void _maybeResolveAudio(RecordingSession s) {
    if (s.audioPath == _lastSeenAudioPath && _audioResolved) return;
    if (s.audioPath == _lastSeenAudioPath) return; // 已经在 resolve
    _lastSeenAudioPath = s.audioPath;
    _resolvedAudioPath = null;
    _audioResolved = false;
    AudioPathResolver.resolve(s.audioPath).then((p) {
      if (!mounted) return;
      // 如果 resolve 期间 audioPath 又变了，丢弃这次结果
      if (s.audioPath != _lastSeenAudioPath) return;
      setState(() {
        _resolvedAudioPath = p;
        _audioResolved = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = _findSession();
    if (session != null) _maybeResolveAudio(session);
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
    if (_reasrInflight) return _buildReasrLoading();

    final segs = s.overallSegments;
    if (segs != null && segs.isNotEmpty) {
      return _buildSegmentsView(s, segs);
    }
    if (s.overallText != null && s.overallText!.isNotEmpty) {
      return _buildLegacyOverallView(s);
    }
    return _buildReasrEmpty(s);
  }

  Widget _buildReasrLoading() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '正在用 Dashscope 重做识别…',
              style: TextStyle(color: Color(0xFF7f8fa6), fontSize: 14),
            ),
            SizedBox(height: 16),
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation(Color(0xFF53a8ff)),
              ),
            ),
            SizedBox(height: 8),
            Text(
              '识别中…（约 10-60 秒）',
              style: TextStyle(color: Color(0xFF7f8fa6), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReasrEmpty(RecordingSession s) {
    final hasAudio = _resolvedAudioPath != null;
    final audioLost = !hasAudio && s.audioPath != null && _audioResolved;
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
              onPressed: hasAudio ? () => _runReasr(s) : null,
            ),
            if (_reasrError != null) ...[
              const SizedBox(height: 12),
              Text(
                _reasrError!,
                style: const TextStyle(color: Color(0xFFe74c3c), fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
            if (s.audioPath == null) ...[
              const SizedBox(height: 12),
              const Text(
                '(此录音没有保存原始音频文件)',
                style: TextStyle(color: Color(0xFF7f8fa6), fontSize: 11),
              ),
            ] else if (audioLost) ...[
              const SizedBox(height: 12),
              const Text(
                '(原始音频文件已丢失，无法重做识别)',
                style: TextStyle(color: Color(0xFF7f8fa6), fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // 新格式：按 VAD 切出的句子级字幕列表。每条卡片显示时间戳 + 原文 + 翻译。
  // 播放时 _activeSegIdx 对应的卡片会高亮（原文变蓝 + 左侧色条）。
  Widget _buildSegmentsView(RecordingSession s, List<TranscriptSegment> segs) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: segs.length + 1,
      itemBuilder: (_, i) {
        if (i == segs.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 16),
            child: Center(
              child: TextButton.icon(
                icon: const Icon(Icons.refresh,
                    size: 16, color: Color(0xFF7f8fa6)),
                label: const Text(
                  '重新识别',
                  style: TextStyle(color: Color(0xFF7f8fa6), fontSize: 12),
                ),
                onPressed: _resolvedAudioPath == null ? null : () => _runReasr(s),
              ),
            ),
          );
        }
        return KeyedSubtree(
          key: _keyForSeg(i),
          child: _buildSegmentCard(segs[i], isActive: i == _activeSegIdx),
        );
      },
    );
  }

  Widget _buildSegmentCard(TranscriptSegment seg, {required bool isActive}) {
    final ts = _fmtSegmentRange(seg.beginMs, seg.endMs);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: isActive
            ? Border.all(color: const Color(0xFF53a8ff), width: 1.5)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            color: const Color(0xFF16213e),
            child: Row(
              children: [
                Text(
                  ts,
                  style: const TextStyle(
                    color: Color(0xFF7f8fa6),
                    fontSize: 11,
                    letterSpacing: 0.5,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  seg.spokenLang,
                  style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF7f8fa6),
                      letterSpacing: 0.5),
                ),
                const Spacer(),
                if (isActive)
                  const Icon(Icons.graphic_eq,
                      size: 14, color: Color(0xFF53a8ff)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
            color: const Color(0xFF16213e),
            child: _buildSegmentBody(seg, isActive: isActive),
          ),
          Container(
            padding: const EdgeInsets.all(14),
            color: const Color(0xFF0f3460),
            child: SelectableText(
              seg.translated.isEmpty ? '(翻译失败)' : seg.translated,
              style: TextStyle(
                fontSize: 16,
                color: seg.translated.isEmpty
                    ? const Color(0xFF7f8fa6)
                    : const Color(0xFF53a8ff),
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // active 卡片：每个 word 是一个独立 widget，根据 (pos - begin) / (end - begin)
  // 计算 0~1 进度，ShaderMask 在字内左→右刷蓝色。
  // 视觉效果：每个字内部从左到右"被蓝色刷过"，刷过整个字所用时间 = 该字真实
  // 发音时长（快字一闪而过，慢字慢慢推）。Wrap 自动换行。
  // 非 active：整段 SelectableText，保留复制能力。
  Widget _buildSegmentBody(TranscriptSegment seg, {required bool isActive}) {
    const readColor = Color(0xFF53a8ff);
    const unreadColor = Color(0xFFe0e0ff);
    final baseStyle = TextStyle(
      fontSize: 16,
      height: 1.5,
      fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
    );
    if (!isActive || seg.words.isEmpty) {
      return SelectableText(
        seg.text,
        style: baseStyle.copyWith(color: isActive ? readColor : unreadColor),
      );
    }
    final posMs = _pos.inMilliseconds;
    return Wrap(
      spacing: 0,
      runSpacing: 0,
      children: seg.words.map((w) {
        final beg = w.beginMs;
        final end = w.endMs;
        double t;
        if (beg == null) {
          t = 0;
        } else if (end == null || end <= beg) {
          t = posMs >= beg ? 1.0 : 0.0;
        } else {
          t = ((posMs - beg) / (end - beg)).clamp(0.0, 1.0);
        }
        return _ProgressWord(
          text: w.text,
          progress: t,
          style: baseStyle,
          readColor: readColor,
          unreadColor: unreadColor,
        );
      }).toList(),
    );
  }

  String _fmtSegmentRange(int? beginMs, int? endMs) {
    String fmt(int? ms) {
      if (ms == null) return '--:--';
      final s = ms ~/ 1000;
      final mm = (s ~/ 60).toString().padLeft(2, '0');
      final ss = (s % 60).toString().padLeft(2, '0');
      return '$mm:$ss';
    }
    return '${fmt(beginMs)} → ${fmt(endMs)}';
  }

  // 老格式（没 segments，只有 overallText）：保留双栏视图做向后兼容。
  Widget _buildLegacyOverallView(RecordingSession s) {
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
                SelectableText(s.overallText!,
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
                SelectableText(s.overallTranslated ?? '...',
                    style: const TextStyle(
                        color: Color(0xFF53a8ff), fontSize: 16, height: 1.5)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: TextButton.icon(
              icon: const Icon(Icons.refresh,
                  size: 16, color: Color(0xFF7f8fa6)),
              label: const Text(
                '重新识别',
                style: TextStyle(color: Color(0xFF7f8fa6), fontSize: 12),
              ),
              onPressed: s.audioPath == null ? null : () => _runReasr(s),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runReasr(RecordingSession s) async {
    if (_reasrInflight) return;
    final abs = _resolvedAudioPath;
    if (abs == null) return;
    setState(() {
      _reasrInflight = true;
      _reasrError = null;
    });
    try {
      final r = await FileRecognizeClient().run(
        audioPath: abs,
        langA: s.langA,
        langB: s.langB,
      );
      if (r.overallText.isEmpty) {
        if (!mounted) return;
        setState(() {
          _reasrInflight = false;
          _reasrError = '识别结果为空，请确认录音内容';
        });
        return;
      }
      final updated = s.copyWith(
        overallText: r.overallText,
        overallTranslated: r.overallTranslated,
        overallSegments: r.segments,
      );
      await _store.update(updated);
      if (!mounted) return;
      setState(() {
        _reasrInflight = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _reasrInflight = false;
        _reasrError = '识别超时，请重试';
      });
    } on SocketException catch (e) {
      if (!mounted) return;
      setState(() {
        _reasrInflight = false;
        _reasrError = '网络错误：${e.message}';
      });
    } on FileRecognizeException catch (e) {
      if (!mounted) return;
      setState(() {
        _reasrInflight = false;
        _reasrError = '服务器错误 ${e.statusCode}：${e.body}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _reasrInflight = false;
        _reasrError = '识别失败：$e';
      });
    }
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
    final path = _resolvedAudioPath;
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
                    value: (_dragValue ?? progress).clamp(0.0, 1.0),
                    onChangeStart: hasAudio
                        ? (v) => setState(() => _dragValue = v)
                        : null,
                    onChanged: hasAudio
                        ? (v) {
                            // 拖动时立即同步 _pos + active seg + word lerp，
                            // 不等 seek，文字跟着指头走。
                            final ms = (v * total.inMilliseconds).round();
                            setState(() {
                              _dragValue = v;
                              _pos = Duration(milliseconds: ms);
                              _authMs = ms;
                              _authAt = DateTime.now();
                            });
                            _updateActiveSegIfNeeded();
                          }
                        : null,
                    onChangeEnd: hasAudio
                        ? (v) async {
                            final ms = (v * total.inMilliseconds).round();
                            if (_playing) {
                              // 正在播 → 用 play(source, position) 让 player 跳到
                              // 新位置继续播放（seek + resume 在 iOS 不靠谱）。
                              await _player.play(DeviceFileSource(path),
                                  position: Duration(milliseconds: ms));
                              _loadedPath = path;
                              _playerLoaded = true;
                            } else {
                              // 没在播 → 仅同步 _pos 到 player 内部位置，下次
                              // 用户按播放时由 _togglePlay 走 play(source, position)。
                              if (_loadedPath != path || !_playerLoaded) {
                                await _player.setSourceDeviceFile(path);
                                _loadedPath = path;
                                _playerLoaded = true;
                              }
                              try {
                                await _player
                                    .seek(Duration(milliseconds: ms));
                              } catch (_) {}
                            }
                            if (!mounted) return;
                            setState(() => _dragValue = null);
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

// 单字"卡拉 OK"刷蓝控件：ShaderMask 用 hard-stop LinearGradient 模拟蓝色条
// 从左到右覆盖文字。progress=0 全白、=1 全蓝、中间则左 progress 比例蓝、右白。
class _ProgressWord extends StatelessWidget {
  final String text;
  final double progress;
  final TextStyle style;
  final Color readColor;
  final Color unreadColor;
  const _ProgressWord({
    required this.text,
    required this.progress,
    required this.style,
    required this.readColor,
    required this.unreadColor,
  });

  @override
  Widget build(BuildContext context) {
    if (progress <= 0.0) {
      return Text(text, style: style.copyWith(color: unreadColor));
    }
    if (progress >= 1.0) {
      return Text(text, style: style.copyWith(color: readColor));
    }
    return ShaderMask(
      shaderCallback: (rect) {
        return LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          stops: [progress, progress],
          colors: [readColor, unreadColor],
        ).createShader(rect);
      },
      blendMode: BlendMode.srcIn,
      child: Text(text, style: style.copyWith(color: Colors.white)),
    );
  }
}
