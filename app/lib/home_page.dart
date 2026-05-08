import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'models/language.dart';
import 'models/transcript_entry.dart';
import 'models/recording.dart';
import 'services/recording_store.dart';
import 'services/audio_file_writer.dart';
import 'recordings_list_page.dart';

class ServerOption {
  final String name;
  final String url;
  // on-device: skip ws/audio upload, run ASR locally; url is the /translate
  // proxy (HTTPS) used to fetch translations after recognition.
  final bool onDevice;
  // engine: 'ws' (cloud relay), 'apple' (SFSpeechRecognizer), 'sherpa'
  // (sherpa-onnx zipformer transducer in the app process).
  final String engine;
  const ServerOption(this.name, this.url,
      {this.onDevice = false, this.engine = 'ws'});
}

const _servers = <ServerOption>[
  ServerOption('Dashscope (Paraformer)', 'wss://translate-relay-dashscope.fly.dev'),
  ServerOption('Whisper', 'wss://translate-relay-whisper.fly.dev'),
  ServerOption('v1 (Google STT)', 'wss://translate-relay.fly.dev'),
  ServerOption('On-Device (Apple Speech)',
      'https://translate-relay-dashscope.fly.dev',
      onDevice: true, engine: 'apple'),
  ServerOption('On-Device (sherpa 8-lang stream + Dashscope re-recog)',
      'https://translate-relay-dashscope.fly.dev',
      onDevice: true, engine: 'sherpa'),
];

const _appVersion = 'v1.3.0';

// TranscriptEntry moved to models/transcript_entry.dart so RecordingSession
// can reuse it. Kept the export for backward compatibility within this file.

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  // Connection state
  bool _isConnected = false;
  bool _isListening = false;

  Language _langA = languages[0]; // Chinese
  Language _langB = languages[2]; // Japanese
  final List<TranscriptEntry> _transcripts = [];
  String _liveText = '';
  String _liveTranslation = '';
  String _status = 'Connecting...';
  int _selectedServer = 0; // 0 = Dashscope (default)
  String get _serverUrl => _servers[_selectedServer].url;

  final _recorder = AudioRecorder();
  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSub;
  StreamSubscription? _audioSub;

  // Tracks the boundary in `_transcripts` for the current Start-Stop window so
  // _stopListening can save just this session's entries (vs the whole running
  // transcript list, which may include earlier sessions the user hasn't
  // cleared yet).
  DateTime? _sessionStartedAt;
  int? _sessionStartTranscriptCount;
  String? _sessionId;
  final _audioWriter = AudioFileWriter();

  // On-device speech (Apple Speech via SFSpeechRecognizer)
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechReady = false;
  String _onDeviceLastFinalText = '';
  int _onDeviceLastTranslateAt = 0;
  String _onDeviceInflightInterim = '';
  Timer? _onDeviceSilenceTimer;
  bool _onDeviceUserStop = false;
  String _onDeviceLastPartial = '';
  // Side-channel from the patched speech_to_text iOS plugin: one 16kHz mono
  // Int16 LE PCM blob per Apple final, pushed via MethodChannel just before
  // the matching textRecognition. _pendingApplePcm holds the latest blob
  // until the final handler picks it up and runs cloud secondary on it.
  static const _appleAudioChannel =
      MethodChannel('plugin.csdcorp.com/speech_to_text/audio_buffer');
  bool _appleAudioHandlerInstalled = false;
  Uint8List? _pendingApplePcm;

  // sherpa-onnx (in-process streaming zipformer transducer, 8 languages)
  so.OnlineRecognizer? _sherpa;
  so.OnlineStream? _sherpaStream;
  StreamSubscription? _sherpaAudioSub;
  bool _sherpaInitInflight = false;
  String _sherpaLastEmitted = '';
  int _sherpaLastTranslateAt = 0;
  // Buffer of raw PCM int16 LE bytes for the current utterance, so we can
  // re-recognize on Dashscope after sherpa endpoints.
  final List<Uint8List> _sherpaSegmentPcm = [];

  final _scrollController = ScrollController();
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  bool _opusInitialized = false;

  bool get _isOnDevice => _servers[_selectedServer].onDevice;
  String get _engine => _servers[_selectedServer].engine;
  bool get _isSherpa => _engine == 'sherpa';
  bool get _isApple => _engine == 'apple';

  @override
  void initState() {
    super.initState();
    _initOpus();
    _initSpeech();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1400),
      vsync: this,
    );
    _pulseAnimation = Tween(begin: 1.0, end: 1.5).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    // Connect to server immediately on app open
    _connectToServer();
  }

  @override
  void dispose() {
    _stopListening();
    _disconnectFromServer();
    _recorder.dispose();
    _pulseController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initOpus() async {
    if (_opusInitialized) return;
    try {
      initOpus(await opus_flutter.load());
      _opusInitialized = true;
    } catch (e) {
      debugPrint('Opus init: $e');
    }
  }

  Future<void> _initSpeech() async {
    if (_speechReady) return;
    try {
      _speechReady = await _speech.initialize(
        onError: (e) => debugPrint('stt error: ${e.errorMsg}'),
        onStatus: (s) {
          debugPrint('stt status: $s');
          // After Apple finalizes (notListening/done), auto-restart unless the
          // user explicitly tapped Stop — gives a continuous listening UX.
          if ((s == 'notListening' || s == 'done') &&
              _isListening &&
              _isOnDevice &&
              !_onDeviceUserStop) {
            Future.delayed(const Duration(milliseconds: 80), () {
              if (mounted && _isListening && _isOnDevice && !_onDeviceUserStop) {
                _restartOnDeviceListen();
              }
            });
          }
        },
      );
    } catch (e) {
      debugPrint('stt init: $e');
    }
  }

  Future<void> _restartOnDeviceListen() async {
    _onDeviceLastPartial = '';
    _onDeviceSilenceTimer?.cancel();
    try {
      await _speech.listen(
        onResult: _onSpeechResult,
        localeId: _langA.code,
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          onDevice: true,
          listenMode: stt.ListenMode.dictation,
          cancelOnError: false,
          autoPunctuation: true,
        ),
      );
    } catch (e) {
      debugPrint('on-device restart: $e');
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        final max = _scrollController.position.maxScrollExtent;
        final current = _scrollController.position.pixels;
        // Only scroll down, never up
        if (max > current) {
          _scrollController.jumpTo(max);
        }
      }
    });
  }

  // ---- WebSocket Connection (app lifecycle) ----

  Future<void> _connectToServer() async {
    if (_isOnDevice) {
      // On-device path uses HTTP /translate proxy on demand; no ws.
      setState(() {
        _isConnected = true;
        _status = _speechReady ? 'Standby (on-device)' : 'On-device unavailable';
      });
      return;
    }
    setState(() => _status = 'Connecting...');

    try {
      _wsChannel = WebSocketChannel.connect(Uri.parse(_serverUrl));
      await _wsChannel!.ready;

      _wsSub = _wsChannel!.stream.listen(
        (data) => _handleServerMessage(data),
        onError: (err) {
          debugPrint('WS error: $err');
          _onDisconnected();
          // Auto reconnect after 3s
          Future.delayed(const Duration(seconds: 3), () {
            if (mounted && !_isConnected) _connectToServer();
          });
        },
        onDone: () {
          debugPrint('WS closed');
          _onDisconnected();
          // Auto reconnect after 3s
          Future.delayed(const Duration(seconds: 3), () {
            if (mounted && !_isConnected) _connectToServer();
          });
        },
      );

      setState(() {
        _isConnected = true;
        _status = 'Standby';
      });
    } catch (e) {
      debugPrint('Connect error: $e');
      setState(() {
        _isConnected = false;
        _status = 'Connection failed';
      });
      // Retry after 3s
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && !_isConnected) _connectToServer();
      });
    }
  }

  void _onDisconnected() {
    if (_isListening) _stopListening();
    setState(() {
      _isConnected = false;
      _status = 'Disconnected';
    });
  }

  void _disconnectFromServer() {
    _wsSub?.cancel();
    _wsSub = null;
    if (_wsChannel != null) {
      try { _wsChannel!.sink.close(); } catch (_) {}
    }
    _wsChannel = null;
    _isConnected = false;
  }

  // ---- Start/Stop Listening (user action) ----

  Future<void> _startListening() async {
    if (_isApple) {
      await _startOnDeviceListening();
      return;
    }
    if (_isSherpa) {
      await _startSherpaListening();
      return;
    }
    if (!_isConnected || _wsChannel == null) return;

    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _showAlert('Permission Required', 'Microphone permission is needed.');
      return;
    }

    // Send start command to server
    _wsChannel!.sink.add(jsonEncode({
      'type': 'start',
      'langA': _langA.code,
      'langB': _langB.code,
    }));

    // Opus encoder
    final encoder = SimpleOpusEncoder(
      sampleRate: 16000,
      channels: 1,
      application: Application.voip,
    );

    // Start recording
    final audioStream = await _recorder.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      bitRate: 256000,
    ));

    const frameSizeBytes = 640; // 20ms @ 16kHz 16bit mono
    List<int> pcmBuffer = [];

    _sessionStartedAt = DateTime.now();
    _sessionId = 'sess_${_sessionStartedAt!.millisecondsSinceEpoch}';
    await _audioWriter.start(sessionId: _sessionId!);

    _audioSub = audioStream.listen((data) {
      _audioWriter.write(data);
      pcmBuffer.addAll(data);
      while (pcmBuffer.length >= frameSizeBytes) {
        final frame = Int16List.view(
          Uint8List.fromList(pcmBuffer.sublist(0, frameSizeBytes)).buffer,
        );
        pcmBuffer = pcmBuffer.sublist(frameSizeBytes);

        try {
          final opusPacket = encoder.encode(input: frame);
          if (_wsChannel != null && opusPacket.isNotEmpty) {
            _wsChannel!.sink.add(Uint8List.fromList(opusPacket));
          }
        } catch (e) {
          debugPrint('Opus encode error: $e');
        }
      }
    });
    _sessionStartTranscriptCount = _transcripts.length;
    setState(() {
      _isListening = true;
      _status = 'Listening...';
      _liveText = '';
      _liveTranslation = '';
    });
    _pulseController.repeat(reverse: true);
    WakelockPlus.enable(); // keep screen on while listening
  }

  Future<void> _stopListening() async {
    _pulseController.stop();
    _pulseController.reset();

    if (_isApple) {
      _onDeviceUserStop = true;
      _onDeviceSilenceTimer?.cancel();
      _onDeviceSilenceTimer = null;
      try { await _speech.stop(); } catch (_) {}
      _pendingApplePcm = null;
    } else if (_isSherpa) {
      await _stopSherpaListening();
    } else {
      _audioSub?.cancel();
      _audioSub = null;

      try { await _recorder.stop(); } catch (_) {}

      // Send stop command (don't close WebSocket!)
      if (_wsChannel != null && _isConnected) {
        try {
          _wsChannel!.sink.add(jsonEncode({'type': 'stop'}));
        } catch (_) {}
      }
    }

    // If there's unsaved interim text, save it as a transcript entry
    if (_liveText.isNotEmpty) {
      _transcripts.add(TranscriptEntry(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        original: _liveText,
        translated: _liveTranslation.isNotEmpty ? _liveTranslation : '...',
        spokenLang: '',
        translatedLang: '',
      ));
    }

    WakelockPlus.disable(); // allow screen to sleep again

    setState(() {
      _isListening = false;
      _status = _isConnected ? (_isOnDevice ? 'Standby (on-device)' : 'Standby') : 'Disconnected';
      _liveText = '';
      _liveTranslation = '';
    });

    _saveSessionIfAny();
  }

  Future<void> _saveSessionIfAny() async {
    final startedAt = _sessionStartedAt;
    final startCount = _sessionStartTranscriptCount;
    final sessionId = _sessionId;
    _sessionStartedAt = null;
    _sessionStartTranscriptCount = null;
    _sessionId = null;
    // Always stop the writer (idempotent) so the m4a file finalizes even if
    // we're going to skip persisting the session.
    final audioPath = await _audioWriter.stop();
    if (startedAt == null || startCount == null || sessionId == null) return;
    final entries = startCount < _transcripts.length
        ? _transcripts.sublist(startCount).map((e) => TranscriptEntry(
              id: e.id,
              original: e.original,
              translated: e.translated,
              spokenLang: e.spokenLang,
              translatedLang: e.translatedLang,
            )).toList()
        : <TranscriptEntry>[];
    if (entries.isEmpty && audioPath == null) return;
    final session = RecordingSession(
      id: sessionId,
      createdAt: startedAt,
      audioPath: audioPath,
      liveTranscripts: entries,
      langA: _langA.code,
      langB: _langB.code,
      serverName: _servers[_selectedServer].name,
      duration: DateTime.now().difference(startedAt),
    );
    RecordingStore.instance.add(session);
  }

  // ---- On-device path (Apple Speech) ----

  Future<void> _startOnDeviceListening() async {
    if (!_speechReady) {
      _showAlert('Unavailable', 'On-device speech is not available. Try another server.');
      return;
    }
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _showAlert('Permission Required', 'Microphone permission is needed.');
      return;
    }

    _onDeviceLastFinalText = '';
    _onDeviceInflightInterim = '';
    _onDeviceLastTranslateAt = 0;
    _onDeviceUserStop = false;
    _onDeviceLastPartial = '';
    _pendingApplePcm = null;
    if (!_appleAudioHandlerInstalled) {
      _appleAudioChannel.setMethodCallHandler((call) async {
        if (call.method == 'buffer' && call.arguments is Uint8List) {
          final blob = call.arguments as Uint8List;
          debugPrint('apple pcm channel buffer: ${blob.length} bytes');
          _pendingApplePcm = blob;
          // Mirror to the on-disk recording. The plugin only flushes per
          // utterance so the resulting m4a is per-utterance segments back to
          // back (silence between SFSpeech endpoints is dropped) — acceptable
          // for playback, and the only stream Apple gives us.
          _audioWriter.write(blob);
        }
      });
      _appleAudioHandlerInstalled = true;
    }

    try {
      await _restartOnDeviceListen();
    } catch (e) {
      _showAlert('On-device error', '$e');
      return;
    }

    _sessionStartedAt = DateTime.now();
    _sessionId = 'sess_${_sessionStartedAt!.millisecondsSinceEpoch}';
    await _audioWriter.start(sessionId: _sessionId!);
    _sessionStartTranscriptCount = _transcripts.length;
    setState(() {
      _isListening = true;
      _status = 'Listening (on-device)';
      _liveText = '';
      _liveTranslation = '';
    });
    _pulseController.repeat(reverse: true);
    WakelockPlus.enable();
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    final text = result.recognizedWords;
    if (text.isEmpty) return;

    // VAD: if partial text stops changing for 1200ms, force-finalize so the
    // user gets a card without having to tap Stop. Apple's dictation mode
    // doesn't endpoint on its own.
    if (!result.finalResult) {
      if (text != _onDeviceLastPartial) {
        _onDeviceLastPartial = text;
        _onDeviceSilenceTimer?.cancel();
        _onDeviceSilenceTimer = Timer(const Duration(milliseconds: 1200), () {
          if (_isListening && _isOnDevice && !_onDeviceUserStop) {
            // Force final by stopping; onStatus will auto-restart listening.
            _speech.stop();
          }
        });
      }
    } else {
      _onDeviceSilenceTimer?.cancel();
      _onDeviceLastPartial = '';
    }

    if (result.finalResult) {
      debugPrint('Apple final: text="$text" pcmLen=${_pendingApplePcm?.length ?? 'null'}');
      // Promote to a transcript entry; translate, then update the entry in place.
      final entryId = DateTime.now().millisecondsSinceEpoch.toString();
      setState(() {
        _liveText = '';
        _liveTranslation = '';
        _transcripts.add(TranscriptEntry(
          id: entryId,
          original: text,
          translated: '...',
          spokenLang: _langA.code,
          translatedLang: _langB.code,
        ));
      });
      _scrollToBottom();
      _translateOnDevice(text, _langB.code).then((translated) {
        if (!mounted) return;
        if (translated == null) return;
        setState(() {
          for (var i = _transcripts.length - 1; i >= 0; i--) {
            if (_transcripts[i].id == entryId) {
              _transcripts[i] = TranscriptEntry(
                id: entryId,
                original: text,
                translated: translated,
                spokenLang: _langA.code,
                translatedLang: _langB.code,
              );
              break;
            }
          }
        });
      });
      // Cloud secondary: pick up this utterance's PCM (delivered just before
      // the final result by the patched plugin) and ship it to Dashscope.
      final pcm = _pendingApplePcm;
      _pendingApplePcm = null;
      if (pcm != null && pcm.length >= 320 * 2) {
        final localText = text;
        () async {
          try {
            await _runSecondaryRecognize(pcm, entryId, localText: localText);
          } catch (e, st) {
            debugPrint('apple secondary threw: $e\n$st');
          }
        }();
      }
      _onDeviceLastFinalText = text;
      return;
    }

    // Interim
    setState(() => _liveText = text);
    _scrollToBottom();

    // Throttled background translate of the latest partial
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _onDeviceLastTranslateAt < 350) return;
    _onDeviceLastTranslateAt = now;
    _onDeviceInflightInterim = text;
    _translateOnDevice(text, _langB.code).then((translated) {
      if (!mounted) return;
      if (translated == null) return;
      // Drop if the partial moved on
      if (_onDeviceInflightInterim != text) return;
      setState(() => _liveTranslation = translated);
    });
  }

  Future<String?> _translateOnDevice(String text, String targetBcp47) async {
    // For sherpa engine the selected server URL points at the dashscope proxy
    // anyway; fall through to the same dashscope /translate endpoint.
    final base = _servers[_selectedServer].url;
    // Target for Google Translate v2: short code (zh-CN keeps script suffix only for zh-TW).
    final target = targetBcp47.toLowerCase() == 'zh-tw' ? 'zh-TW' : targetBcp47.split('-')[0];
    try {
      final res = await http.post(
        Uri.parse('$base/translate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'text': text, 'target': target}),
      ).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return data['translated'] as String?;
    } catch (_) {
      return null;
    }
  }

  // ---- On-device path (sherpa-onnx zipformer transducer, in-process) ----

  Future<String> _copyAssetToFile(String assetPath, String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    if (!await file.exists()) {
      final byteData = await rootBundle.load(assetPath);
      await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
    }
    return file.path;
  }

  Future<so.OnlineRecognizer?> _initSherpa() async {
    if (_sherpa != null) return _sherpa;
    if (_sherpaInitInflight) {
      while (_sherpaInitInflight) {
        await Future.delayed(const Duration(milliseconds: 80));
      }
      return _sherpa;
    }
    _sherpaInitInflight = true;
    try {
      final encoder = await _copyAssetToFile(
          'assets/models/multi-stream/encoder-epoch-75-avg-11-chunk-16-left-128.int8.onnx',
          'sh-multi-encoder.onnx');
      final decoder = await _copyAssetToFile(
          'assets/models/multi-stream/decoder-epoch-75-avg-11-chunk-16-left-128.onnx',
          'sh-multi-decoder.onnx');
      final joiner = await _copyAssetToFile(
          'assets/models/multi-stream/joiner-epoch-75-avg-11-chunk-16-left-128.int8.onnx',
          'sh-multi-joiner.onnx');
      final tokens = await _copyAssetToFile(
          'assets/models/multi-stream/tokens.txt', 'sh-multi-tokens.txt');
      so.initBindings();
      _sherpa = so.OnlineRecognizer(so.OnlineRecognizerConfig(
        model: so.OnlineModelConfig(
          transducer: so.OnlineTransducerModelConfig(
            encoder: encoder, decoder: decoder, joiner: joiner,
          ),
          tokens: tokens,
          modelType: 'zipformer2',
          numThreads: 2,
        ),
        decodingMethod: 'greedy_search',
        enableEndpoint: true,
        rule1MinTrailingSilence: 2.0,
        rule2MinTrailingSilence: 0.8,
        rule3MinUtteranceLength: 20,
      ));
    } catch (e) {
      debugPrint('sherpa init: $e');
    } finally {
      _sherpaInitInflight = false;
    }
    return _sherpa;
  }

  Future<void> _startSherpaListening() async {
    setState(() => _status = 'Loading model...');
    final rec = await _initSherpa();
    if (rec == null) {
      _showAlert('Sherpa unavailable', 'Failed to load model.');
      setState(() => _status = 'Standby');
      return;
    }
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _showAlert('Permission Required', 'Microphone permission is needed.');
      setState(() => _status = 'Standby');
      return;
    }
    _sherpaStream = rec.createStream();
    _sherpaLastEmitted = '';
    _sherpaLastTranslateAt = 0;
    _sherpaSegmentPcm.clear();

    final audioStream = await _recorder.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      bitRate: 256000,
    ));

    _sessionStartedAt = DateTime.now();
    _sessionId = 'sess_${_sessionStartedAt!.millisecondsSinceEpoch}';
    await _audioWriter.start(sessionId: _sessionId!);

    _sherpaAudioSub = audioStream.listen(_onSherpaAudio);

    _sessionStartTranscriptCount = _transcripts.length;
    setState(() {
      _isListening = true;
      _status = 'Listening (sherpa-onnx 8-lang)';
      _liveText = '';
      _liveTranslation = '';
    });
    _pulseController.repeat(reverse: true);
    WakelockPlus.enable();
  }

  void _onSherpaAudio(Uint8List data) {
    _audioWriter.write(data);
    final rec = _sherpa;
    final stream = _sherpaStream;
    if (rec == null || stream == null) return;
    // Convert PCM int16 LE → Float32 [-1, 1]
    final bytes = Uint8List.fromList(data);
    final int16 = Int16List.view(bytes.buffer);
    final samples = Float32List(int16.length);
    for (var i = 0; i < int16.length; i++) {
      samples[i] = int16[i] / 32768.0;
    }
    stream.acceptWaveform(samples: samples, sampleRate: 16000);
    // Buffer raw PCM for cloud secondary recognition on endpoint.
    _sherpaSegmentPcm.add(bytes);
    while (rec.isReady(stream)) {
      rec.decode(stream);
    }
    final text = rec.getResult(stream).text;
    final isEndpoint = rec.isEndpoint(stream);

    if (isEndpoint) {
      if (text.isNotEmpty) {
        final entryId = DateTime.now().millisecondsSinceEpoch.toString();
        final localText = _normalizeSherpaCase(text);
        _emitSherpaFinal(localText, entryId: entryId);
        final segmentPcm = _flattenChunks(_sherpaSegmentPcm);
        _sherpaSegmentPcm.clear();
        _runSecondaryRecognize(segmentPcm, entryId, localText: localText);
      } else {
        _sherpaSegmentPcm.clear();
      }
      rec.reset(stream);
      _sherpaLastEmitted = '';
    } else if (text.isNotEmpty && text != _sherpaLastEmitted) {
      _sherpaLastEmitted = text;
      _emitSherpaInterim(_normalizeSherpaCase(text));
    }
  }

  void _emitSherpaInterim(String text) {
    setState(() => _liveText = text);
    _scrollToBottom();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _sherpaLastTranslateAt < 350) return;
    _sherpaLastTranslateAt = now;
    final inflightCopy = text;
    _translateOnDevice(text, _langB.code).then((translated) {
      if (!mounted || translated == null) return;
      if (_sherpaLastEmitted != inflightCopy) return;
      setState(() => _liveTranslation = translated);
    });
  }

  Uint8List _flattenChunks(List<Uint8List> chunks) {
    var total = 0;
    for (final c in chunks) total += c.length;
    final out = Uint8List(total);
    var off = 0;
    for (final c in chunks) {
      out.setRange(off, off + c.length, c);
      off += c.length;
    }
    return out;
  }

  // The bilingual zh-en zipformer emits English BPE tokens in all-caps.
  // Lowercase all-caps Latin words and recapitalize sentence-initial letters
  // so the transcript reads naturally. CJK characters are left untouched.
  String _normalizeSherpaCase(String t) {
    var out = t.replaceAllMapped(
      RegExp(r"\b[A-Z][A-Z'’]*\b"),
      (m) => m[0]!.toLowerCase(),
    );
    out = out.replaceAllMapped(
      RegExp(r"(^|[.!?]\s+)([a-z])"),
      (m) => '${m[1]}${m[2]!.toUpperCase()}',
    );
    return out;
  }

  void _emitSherpaFinal(String text, {required String entryId}) {
    setState(() {
      _liveText = '';
      _liveTranslation = '';
      _transcripts.add(TranscriptEntry(
        id: entryId, original: text, translated: '...',
        spokenLang: _langA.code, translatedLang: _langB.code,
      ));
    });
    _scrollToBottom();
    _translateOnDevice(text, _langB.code).then((translated) {
      if (!mounted || translated == null) return;
      _replaceEntry(entryId, original: text, translated: translated);
    });
  }

  void _replaceEntry(String entryId, {required String original, required String translated}) {
    setState(() {
      for (var i = _transcripts.length - 1; i >= 0; i--) {
        if (_transcripts[i].id == entryId) {
          _transcripts[i] = TranscriptEntry(
            id: entryId,
            original: original,
            translated: translated,
            spokenLang: _transcripts[i].spokenLang,
            translatedLang: _transcripts[i].translatedLang,
          );
          break;
        }
      }
    });
  }

  // Send the buffered PCM of one utterance to Dashscope via the existing ws
  // protocol (start + opus frames + stop). When a final text comes back,
  // replace the sherpa-emitted transcript entry with Dashscope's version and
  // refresh its translation.
  Future<void> _runSecondaryRecognize(Uint8List pcm, String entryId,
      {String? localText}) async {
    if (pcm.length < 320 * 2) return; // <20ms — nothing to recognize
    WebSocketChannel? ch;
    try {
      ch = WebSocketChannel.connect(
          Uri.parse('wss://translate-relay-dashscope.fly.dev'));
      await ch.ready;
    } catch (e) {
      debugPrint('secondary connect: $e');
      return;
    }
    String? finalText;
    String? finalTranslated;
    bool done = false;
    final sub = ch.stream.listen((data) {
      if (data is! String) return;
      try {
        final m = jsonDecode(data) as Map<String, dynamic>;
        if (m['type'] == 'final') {
          finalText = m['text'] as String?;
          finalTranslated = m['translated'] as String?;
          done = true;
        }
      } catch (_) {}
    }, onError: (_) { done = true; }, onDone: () { done = true; });

    ch.sink.add(jsonEncode({
      'type': 'start',
      'langA': _langA.code,
      'langB': _langB.code,
    }));
    // Encode PCM int16 → Opus 20ms frames (320 samples = 640 bytes per frame).
    final encoder = SimpleOpusEncoder(
      sampleRate: 16000, channels: 1, application: Application.voip,
    );
    const frameBytes = 640;
    var sent = 0;
    // Copy into a fresh ByteBuffer so Int16List.view alignment holds even when
    // pcm came across a method channel with a non-zero offsetInBytes (Apple
    // path). The sherpa path's PCM is always offset=0 so it didn't hit this.
    final aligned = Uint8List.fromList(pcm);
    for (var i = 0; i + frameBytes <= aligned.length; i += frameBytes) {
      final frame = Int16List.view(aligned.buffer, i, 320);
      try {
        final opus = encoder.encode(input: frame);
        if (opus.isNotEmpty) {
          ch.sink.add(Uint8List.fromList(opus));
          sent++;
        }
      } catch (_) {}
    }
    debugPrint('secondary: sent $sent frames (${(sent * 20 / 1000).toStringAsFixed(1)}s)');
    // Brief drain so the server can finalize trailing frames before stop.
    await Future.delayed(const Duration(milliseconds: 400));
    try { ch.sink.add(jsonEncode({'type': 'stop'})); } catch (_) {}

    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (!done && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    await sub.cancel();
    try { await ch.sink.close(); } catch (_) {}

    if (!mounted) return;
    final cloudText = (finalText ?? '').trim();
    if (cloudText.isEmpty) return;
    // Sanity checks: keep the local result if dashscope is wildly off, either
    // (a) length differs >2x, or (b) character set overlap with the local
    // text is below 30% (catches dashscope hallucinating an unrelated short
    // sentence with similar length). CJK chars make set-based overlap a
    // reasonable similarity proxy.
    if (localText != null && localText.isNotEmpty) {
      final localLen = localText.length;
      final cloudLen = cloudText.length;
      if (cloudLen > localLen * 2 || cloudLen * 2 < localLen) {
        debugPrint('secondary: length mismatch (local=$localLen cloud=$cloudLen), keeping local');
        return;
      }
      final aChars = localText.runes.toSet();
      final bChars = cloudText.runes.toSet();
      final overlap = aChars.intersection(bChars).length;
      final ratio = aChars.isEmpty ? 0.0 : overlap / aChars.length;
      if (ratio < 0.3) {
        debugPrint('secondary: char overlap too low ($ratio), local="$localText" cloud="$cloudText" — keeping local');
        return;
      }
    }
    if (finalTranslated != null && finalTranslated!.isNotEmpty) {
      _replaceEntry(entryId, original: cloudText, translated: finalTranslated!);
    } else {
      // Translate ourselves if Dashscope didn't (e.g. translate timed out).
      _replaceEntry(entryId, original: cloudText, translated: '...');
      final translated = await _translateOnDevice(cloudText, _langB.code);
      if (mounted && translated != null) {
        _replaceEntry(entryId, original: cloudText, translated: translated);
      }
    }
  }

  Future<void> _stopSherpaListening() async {
    _sherpaAudioSub?.cancel();
    _sherpaAudioSub = null;
    try { await _recorder.stop(); } catch (_) {}
    // Flush trailing audio: ask the recognizer to finalize whatever's in flight.
    final rec = _sherpa;
    final stream = _sherpaStream;
    if (rec != null && stream != null) {
      stream.inputFinished();
      while (rec.isReady(stream)) {
        rec.decode(stream);
      }
      final text = rec.getResult(stream).text;
      if (text.isNotEmpty) {
        final entryId = DateTime.now().millisecondsSinceEpoch.toString();
        final localText = _normalizeSherpaCase(text);
        _emitSherpaFinal(localText, entryId: entryId);
        final segmentPcm = _flattenChunks(_sherpaSegmentPcm);
        _sherpaSegmentPcm.clear();
        _runSecondaryRecognize(segmentPcm, entryId, localText: localText);
      }
    }
    _sherpaStream?.free();
    _sherpaStream = null;
    _sherpaSegmentPcm.clear();
  }

  // ---- Server Messages ----

  void _handleServerMessage(dynamic data) {
    if (data is! String) return;

    try {
      final msg = jsonDecode(data) as Map<String, dynamic>;
      final type = msg['type'] as String?;

      if (type == 'interim') {
        setState(() {
          _liveText = msg['text'] as String? ?? '';
        });
        _scrollToBottom();
      } else if (type == 'interim_translation') {
        setState(() {
          _liveText = msg['text'] as String? ?? '';
          _liveTranslation = msg['translated'] as String? ?? '';
        });
        _scrollToBottom();
      } else if (type == 'final') {
        final finalText = msg['text'] as String? ?? '';
        final translated = msg['translated'] as String? ?? '';
        // serverDashscope sends `lang` (spoken BCP-47); serverWhisper sends `spokenLang`/`translatedLang`.
        final lang = msg['lang'] as String? ?? '';
        final spokenLang = (msg['spokenLang'] as String?)?.isNotEmpty == true
            ? msg['spokenLang'] as String
            : lang;
        final translatedLang = (msg['translatedLang'] as String?)?.isNotEmpty == true
            ? msg['translatedLang'] as String
            : (spokenLang == _langA.code ? _langB.code : _langA.code);

        final isDuplicate = _transcripts.isNotEmpty &&
            _transcripts.last.original == finalText;

        if (isDuplicate) {
          // Update translation only, no layout change
          if (translated.isNotEmpty && translated != '...') {
            setState(() {
              final last = _transcripts.removeLast();
              _transcripts.add(TranscriptEntry(
                id: last.id,
                original: last.original,
                translated: translated,
                spokenLang: spokenLang.isNotEmpty ? spokenLang : last.spokenLang,
                translatedLang: translatedLang.isNotEmpty ? translatedLang : last.translatedLang,
              ));
            });
          }
        } else {
          setState(() {
            _liveText = '';
            _liveTranslation = '';
            _transcripts.add(TranscriptEntry(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              original: finalText,
              translated: translated,
              spokenLang: spokenLang,
              translatedLang: translatedLang,
            ));
          });
        }
        _scrollToBottom();
      } else if (type == 'update_last') {
        // Fragment merged into last card
        if (_transcripts.isNotEmpty) {
          setState(() {
            final last = _transcripts.removeLast();
            _transcripts.add(TranscriptEntry(
              id: last.id,
              original: msg['text'] as String? ?? last.original,
              translated: msg['translated'] as String? ?? last.translated,
              spokenLang: msg['spokenLang'] as String? ?? last.spokenLang,
              translatedLang: msg['translatedLang'] as String? ?? last.translatedLang,
            ));
          });
          _scrollToBottom();
        }
      }
    } catch (e) {
      debugPrint('Parse error: $e');
    }
  }

  // ---- UI Helpers ----

  void _swapLanguages() {
    // On-device mode: SFSpeechRecognizer is single-locale; swap mid-listening
    // just retargets the recognizer to the new langA so the user can quickly
    // switch which language they're speaking in.
    if (_isListening && _isApple) {
      // SFSpeechRecognizer is single-locale: swap retargets recognizer.
      setState(() {
        final t = _langA;
        _langA = _langB;
        _langB = t;
        _liveText = '';
        _liveTranslation = '';
      });
      _onDeviceSilenceTimer?.cancel();
      _speech.stop().then((_) {
        if (!mounted || !_isListening || _onDeviceUserStop) return;
        _restartOnDeviceListen();
      });
      return;
    }
    if (_isListening && _isSherpa) {
      // sherpa-onnx zh-en is bilingual; just swap translation direction.
      setState(() {
        final t = _langA;
        _langA = _langB;
        _langB = t;
        _liveText = '';
        _liveTranslation = '';
      });
      return;
    }
    if (_isListening) {
      _showAlert('Notice', 'Stop before swapping.');
      return;
    }
    setState(() {
      final t = _langA;
      _langA = _langB;
      _langB = t;
    });
  }

  void _showAlert(String title, String msg) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(msg),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK')),
        ],
      ),
    );
  }

  void _showSettings() {
    if (_isListening) {
      _showAlert('Notice', 'Stop before switching server.');
      return;
    }
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF16213e),
        title: const Text('Server',
            style: TextStyle(color: Color(0xFFe0e0ff))),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (int i = 0; i < _servers.length; i++)
                RadioListTile<int>(
                  value: i,
                  groupValue: _selectedServer,
                  onChanged: (v) {
                    if (v == null || v == _selectedServer) {
                      Navigator.pop(context);
                      return;
                    }
                    Navigator.pop(context);
                    setState(() => _selectedServer = v);
                    _disconnectFromServer();
                    _connectToServer();
                    // Pre-warm sherpa-onnx model on selection so the first
                    // Start tap doesn't pay the load cost. _initSherpa is
                    // idempotent and never releases, so subsequent selections
                    // are no-ops.
                    if (_servers[v].engine == 'sherpa') {
                      _initSherpa();
                    }
                  },
                  title: Text(_servers[i].name,
                      style: const TextStyle(color: Color(0xFFe0e0ff))),
                  subtitle: Text(_servers[i].url,
                      style: const TextStyle(
                          color: Color(0xFF7f8fa6), fontSize: 11)),
                  activeColor: const Color(0xFF53a8ff),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  void _showLanguagePicker(
      Language current, ValueChanged<Language> onSelect) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1a1a2e),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Select Language',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFe0e0ff))),
          const SizedBox(height: 12),
          ...languages.map((lang) => ListTile(
                title: Text(lang.name,
                    style: TextStyle(
                      color: lang.code == current.code
                          ? const Color(0xFF53a8ff)
                          : const Color(0xFFe0e0ff),
                      fontWeight: lang.code == current.code
                          ? FontWeight.bold
                          : FontWeight.normal,
                    )),
                selected: lang.code == current.code,
                selectedTileColor: const Color(0xFF0f3460),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                onTap: () {
                  onSelect(lang);
                  Navigator.pop(context);
                },
              )),
        ],
      ),
    );
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    // Start button enabled only when connected and not listening
    final canStart = _isConnected && !_isListening;

    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        const Text('Real-time Translator',
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFFe0e0ff))),
                        const SizedBox(width: 8),
                        Text(_appVersion,
                            style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF7f8fa6))),
                      ],
                    ),
                  ),
                  // Connection indicator
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: _isConnected
                          ? const Color(0xFF4ecca3)
                          : const Color(0xFFe74c3c),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings,
                        color: Color(0xFF7f8fa6), size: 20),
                    onPressed: _showSettings,
                  ),
                ],
              ),
            ),

            // Language bar
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF16213e),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => !_isListening
                          ? _showLanguagePicker(
                              _langA, (l) => setState(() => _langA = l))
                          : null,
                      child: Center(
                          child: Text(_langA.name,
                              style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFe0e0ff)))),
                    ),
                  ),
                  GestureDetector(
                    onTap: _swapLanguages,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0f3460),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: const Center(
                          child: Text('→',
                              style: TextStyle(
                                  color: Color(0xFF53a8ff),
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold))),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => !_isListening
                          ? _showLanguagePicker(
                              _langB, (l) => setState(() => _langB = l))
                          : null,
                      child: Center(
                          child: Text(_langB.name,
                              style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFe0e0ff)))),
                    ),
                  ),
                ],
              ),
            ),

            // Transcript list + live area
            Expanded(
              child: Column(
                children: [
                  // Scrollable card list (reverse: new items appear at bottom without shifting old ones)
                  Expanded(
                    child: _transcripts.isEmpty && _liveText.isEmpty && !_isListening
                        ? Center(
                            child: Text(
                              _isConnected
                                  ? 'Speak in either language\nauto-detect & translate'
                                  : 'Connecting to server...',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Color(0xFF7f8fa6), fontSize: 16),
                            ),
                          )
                        : ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.all(16),
                            itemCount: _transcripts.length,
                            itemBuilder: (context, index) {
                              return _buildEntry(_transcripts[index]);
                            },
                          ),
                  ),
                  // Live area fixed at bottom (outside ListView)
                  if (_liveText.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _buildLive(),
                    ),
                ],
              ),
            ),

            // Status
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_isListening)
                    AnimatedBuilder(
                      animation: _pulseAnimation,
                      builder: (_, __) => Transform.scale(
                        scale: _pulseAnimation.value,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: const Color(0xFF4ecca3),
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                      ),
                    )
                  else
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _isConnected
                            ? const Color(0xFF4ecca3)
                            : const Color(0xFF7f8fa6),
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(_status,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Color(0xFF7f8fa6), fontSize: 13)),
                  ),
                ],
              ),
            ),

            // Controls
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isListening
                          ? _stopListening
                          : (canStart ? _startListening : null),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isListening
                            ? const Color(0xFFe74c3c)
                            : const Color(0xFF4ecca3),
                        disabledBackgroundColor: const Color(0xFF2a2a3e),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                      child: Text(
                        _isListening ? 'Stop' : 'Start',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: _isListening
                              ? Colors.white
                              : canStart
                                  ? const Color(0xFF1a1a2e)
                                  : const Color(0xFF7f8fa6),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton(
                    onPressed: () => setState(() => _transcripts.clear()),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF16213e),
                      padding: const EdgeInsets.symmetric(
                          vertical: 16, horizontal: 24),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    child: const Text('Clear',
                        style: TextStyle(
                            color: Color(0xFF7f8fa6),
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntry(TranscriptEntry entry) {
    return Container(
      key: ValueKey(entry.id),
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
                Text(entry.spokenLang,
                    style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF7f8fa6),
                        letterSpacing: 0.5)),
                const SizedBox(height: 4),
                Text(entry.original,
                    style: const TextStyle(
                        fontSize: 16,
                        color: Color(0xFFe0e0ff),
                        height: 1.5)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(14),
            color: const Color(0xFF0f3460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.translatedLang,
                    style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF7f8fa6),
                        letterSpacing: 0.5)),
                const SizedBox(height: 4),
                Text(entry.translated,
                    style: const TextStyle(
                        fontSize: 16,
                        color: Color(0xFF53a8ff),
                        height: 1.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLive() {
    return Container(
      key: const ValueKey('__live__'),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: const Border(
            left: BorderSide(color: Color(0xFF4ecca3), width: 3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Opacity(
        opacity: 0.8,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              color: const Color(0xFF16213e),
              child: Text(_liveText,
                  style: const TextStyle(
                      fontSize: 16,
                      color: Color(0xFFe0e0ff),
                      height: 1.5)),
            ),
            Container(
              padding: const EdgeInsets.all(14),
              color: const Color(0xFF0f3460),
              child: Text(
                  _liveTranslation.isNotEmpty ? _liveTranslation : '...',
                  style: TextStyle(
                      fontSize: _liveTranslation.isNotEmpty ? 16 : 14,
                      color: _liveTranslation.isNotEmpty
                          ? const Color(0xFF53a8ff)
                          : const Color(0xFF7f8fa6),
                      fontStyle: FontStyle.italic)),
            ),
          ],
        ),
      ),
    );
  }
}
