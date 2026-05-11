import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart'
    show MethodChannel, PlatformException, rootBundle;
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
import 'services/audio_path_resolver.dart';
import 'recordings_list_page.dart';

class ServerOption {
  final String name;
  final String url;
  // on-device: skip ws/audio upload, run ASR locally; url is the /translate
  // proxy (HTTPS) used to fetch translations after recognition.
  final bool onDevice;
  // engine:
  //   'ws'            cloud relay (Dashscope/Whisper/Google)
  //   'apple'         Apple SFSpeech + Dashscope cloud secondary + Google translate
  //   'apple-native'  Apple SFSpeech + Apple Translation framework, no cloud
  //   'sherpa'        sherpa-onnx 8-lang streaming + Dashscope cloud secondary
  //   'sherpa-single' sherpa-onnx single-lang (zh/en streaming, ja VAD+offline moonshine)
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
  ServerOption('On-Device (sherpa single-lang, local only)',
      'https://translate-relay-dashscope.fly.dev',
      onDevice: true, engine: 'sherpa-single'),
  ServerOption('On-Device (Apple ASR + Apple Translation, fully local)',
      'https://translate-relay-dashscope.fly.dev',
      onDevice: true, engine: 'apple-native'),
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
  int _selectedServer = 3; // 3 = On-Device (Apple Speech) — default
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
  // Apple mode writes its m4a inside the patched plugin (audio tap → AAC),
  // bypassing the Runner-side AudioFileWriter to avoid the cross-thread
  // dispatch that caused crashes when streaming PCM via method channel.
  String? _appleRecordingPath;

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
  // Direct line into the patched speech_to_text plugin for the two custom
  // methods that aren't exposed by the SpeechToText Dart wrapper:
  //   setKeepAudioEngineAlive — silence stops only finish the SFSpeech task,
  //   fullStop — actually tear the audio engine down (called on user Stop).
  static const _appleSttChannel =
      MethodChannel('plugin.csdcorp.com/speech_to_text');
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
  // Which sherpa model bundle is currently loaded into _sherpa / _sherpaOffline.
  // Values: null (none), 'multi' (8-lang), 'zh-single', 'en-single', 'ja-single'.
  String? _sherpaModelKey;
  // sherpa-onnx single-lang ja path: offline moonshine + silero VAD.
  so.OfflineRecognizer? _sherpaOffline;
  so.VoiceActivityDetector? _vad;

  final _scrollController = ScrollController();
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  bool _opusInitialized = false;

  bool get _isOnDevice => _servers[_selectedServer].onDevice;
  String get _engine => _servers[_selectedServer].engine;
  // Any sherpa-onnx-based engine.
  bool get _isSherpa => _engine == 'sherpa' || _engine == 'sherpa-single';
  // Single-lang sherpa: skip cloud secondary, pick model from langA.
  bool get _isSherpaSingle => _engine == 'sherpa-single';
  // Any Apple SFSpeech-based engine.
  bool get _isApple => _engine == 'apple' || _engine == 'apple-native';
  // Apple-native: skip Dashscope cloud secondary; use Apple Translation framework.
  bool get _isAppleNative => _engine == 'apple-native';

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
    _disposeSherpaModels();
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
      // Tell the patched plugin to keep its AVAudioEngine + tap running across
      // silence-induced stop()s so the recording archive gets a continuous
      // file. Paired with the fullStop call in _stopListening's Apple branch.
      try {
        await _appleSttChannel.invokeMethod('setKeepAudioEngineAlive', true);
      } catch (_) {}
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
      // closeRecordingFile finalizes the m4a (writes moov atom). fullStop
      // then tears down the AVAudioEngine so the mic releases.
      try { await _appleSttChannel.invokeMethod('closeRecordingFile'); } catch (_) {}
      try { await _appleSttChannel.invokeMethod('fullStop'); } catch (_) {}
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

  Future<String?> _openAppleRecordingFile(String sessionId) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final outDir = Directory('${dir.path}/recordings');
      if (!await outDir.exists()) await outDir.create(recursive: true);
      final path = '${outDir.path}/$sessionId.m4a';
      await _appleSttChannel.invokeMethod('openRecordingFile', {'path': path});
      return path;
    } catch (e) {
      debugPrint('apple openRecordingFile: $e');
      return null;
    }
  }

  Future<void> _saveSessionIfAny() async {
    final startedAt = _sessionStartedAt;
    final startCount = _sessionStartTranscriptCount;
    final sessionId = _sessionId;
    _sessionStartedAt = null;
    _sessionStartTranscriptCount = null;
    _sessionId = null;
    // Always stop the (Runner-side) writer used by ws/sherpa. Apple wrote
    // its file inside the plugin, _appleRecordingPath holds the path.
    final writerPath = await _audioWriter.stop();
    String? audioPath;
    if (_appleRecordingPath != null) {
      final p = _appleRecordingPath!;
      _appleRecordingPath = null;
      try {
        final f = File(p);
        if (await f.exists() && await f.length() > 1024) {
          audioPath = p;
        } else if (await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    } else {
      audioPath = writerPath;
    }
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
    // 只存相对路径（recordings/xxx.m4a），避免重装后 iOS data container UUID
    // 变了导致绝对路径失效。播放/上传时通过 AudioPathResolver 重新拼成绝对路径。
    final finalAudioPath = audioPath == null
        ? null
        : AudioPathResolver.toRelative(audioPath);
    if (entries.isEmpty && finalAudioPath == null) return;
    final session = RecordingSession(
      id: sessionId,
      createdAt: startedAt,
      audioPath: finalAudioPath,
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
          _pendingApplePcm = call.arguments as Uint8List;
        }
      });
      _appleAudioHandlerInstalled = true;
    }
    // Apple-native engine: kick off language pack prepare/download now (on
    // Start), so the iOS "Download language" prompt appears up front rather
    // than mid-utterance when the first translation tries to fire.
    if (_isAppleNative) {
      unawaited(_prepareApple(_langA.code, _langB.code));
    }

    try {
      await _restartOnDeviceListen();
    } catch (e) {
      _showAlert('On-device error', '$e');
      return;
    }

    _sessionStartedAt = DateTime.now();
    _sessionId = 'sess_${_sessionStartedAt!.millisecondsSinceEpoch}';
    // Tell the patched plugin to start writing m4a directly from its audio
    // tap. We bypass _audioWriter (Runner side) for Apple mode because
    // method-channel-streamed PCM crashed under load.
    _appleRecordingPath = await _openAppleRecordingFile(_sessionId!);
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
      // Apple-native engine is "fully local" — skip the cloud upgrade.
      final pcm = _pendingApplePcm;
      _pendingApplePcm = null;
      if (!_isAppleNative && pcm != null && pcm.length >= 320 * 2) {
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

  // Dart-side bridge to Apple's Translation framework (iOS 18.0+). Returns
  // null if the framework isn't available (older iOS) or the call fails.
  static const _appleTranslateChannel =
      MethodChannel('app.translate/apple_translation');

  Future<String?> _translateApple(
      String text, String sourceBcp47, String targetBcp47) async {
    try {
      final result = await _appleTranslateChannel.invokeMethod<String>(
        'translate',
        {'text': text, 'source': sourceBcp47, 'target': targetBcp47},
      );
      if (result == null || result.isEmpty) return null;
      return result;
    } on PlatformException catch (e) {
      debugPrint('apple translate: ${e.code} ${e.message}');
      return null;
    } catch (e) {
      debugPrint('apple translate: $e');
      return null;
    }
  }

  // Ask iOS to prepare (download if needed) the source→target language pair so
  // the iOS Translation download prompt appears now, when the user taps Start,
  // rather than on the first inflight translation mid-utterance.
  Future<void> _prepareApple(String sourceBcp47, String targetBcp47) async {
    try {
      await _appleTranslateChannel.invokeMethod<void>(
        'prepare',
        {'source': sourceBcp47, 'target': targetBcp47},
      );
    } on PlatformException catch (e) {
      debugPrint('apple prepare: ${e.code} ${e.message}');
    } catch (e) {
      debugPrint('apple prepare: $e');
    }
  }

  Future<String?> _translateOnDevice(String text, String targetBcp47) async {
    // Apple-native engine routes translation through the iOS Translation
    // framework instead of the cloud /translate proxy.
    if (_isAppleNative) {
      return _translateApple(text, _langA.code, targetBcp47);
    }
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

  // Pick which sherpa model bundle to load given the current engine + langA.
  // sherpa-single picks zh/en streaming or ja offline+VAD; sherpa always uses
  // the 8-lang multi-stream model.
  String _resolveSherpaModelKey() {
    if (!_isSherpaSingle) return 'multi';
    final code = _langA.code.toLowerCase();
    if (code.startsWith('zh')) return 'zh-single';
    if (code.startsWith('en')) return 'en-single';
    if (code.startsWith('ja')) return 'ja-single';
    return 'multi';
  }

  // Tear down whichever sherpa recognizer + VAD is currently loaded so we can
  // swap to a different model bundle. Safe to call repeatedly.
  void _disposeSherpaModels() {
    try { _sherpaStream?.free(); } catch (_) {}
    _sherpaStream = null;
    try { _sherpa?.free(); } catch (_) {}
    _sherpa = null;
    try { _sherpaOffline?.free(); } catch (_) {}
    _sherpaOffline = null;
    try { _vad?.free(); } catch (_) {}
    _vad = null;
    _sherpaModelKey = null;
  }

  // Load (or swap to) the sherpa model bundle implied by the current engine +
  // langA. Returns true on success. Safe to call multiple times; if the wanted
  // bundle is already loaded, it's a no-op.
  Future<bool> _ensureSherpa() async {
    final wanted = _resolveSherpaModelKey();
    final alreadyLoaded = (_sherpaModelKey == wanted) &&
        (wanted == 'ja-single'
            ? (_sherpaOffline != null && _vad != null)
            : _sherpa != null);
    if (alreadyLoaded) return true;
    if (_sherpaInitInflight) {
      while (_sherpaInitInflight) {
        await Future.delayed(const Duration(milliseconds: 80));
      }
      return _sherpaModelKey == wanted;
    }
    _disposeSherpaModels();
    _sherpaInitInflight = true;
    try {
      so.initBindings();
      switch (wanted) {
        case 'multi':
          await _loadSherpaMulti();
          break;
        case 'zh-single':
          await _loadSherpaSingleStreaming(
            langKey: 'zh',
            assetPrefix: 'assets/models/zh',
            cachePrefix: 'sh-zh-single',
          );
          break;
        case 'en-single':
          await _loadSherpaSingleStreaming(
            langKey: 'en',
            assetPrefix: 'assets/models/en',
            cachePrefix: 'sh-en-single',
          );
          break;
        case 'ja-single':
          await _loadSherpaJaOfflineWithVad();
          break;
      }
      _sherpaModelKey = wanted;
      return true;
    } catch (e) {
      debugPrint('sherpa ensure $wanted: $e');
      _disposeSherpaModels();
      return false;
    } finally {
      _sherpaInitInflight = false;
    }
  }

  Future<void> _loadSherpaMulti() async {
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
  }

  Future<void> _loadSherpaSingleStreaming({
    required String langKey,
    required String assetPrefix,
    required String cachePrefix,
  }) async {
    final encoder = await _copyAssetToFile(
        '$assetPrefix/encoder.onnx', '$cachePrefix-encoder.onnx');
    final decoder = await _copyAssetToFile(
        '$assetPrefix/decoder.onnx', '$cachePrefix-decoder.onnx');
    final joiner = await _copyAssetToFile(
        '$assetPrefix/joiner.onnx', '$cachePrefix-joiner.onnx');
    final tokens = await _copyAssetToFile(
        '$assetPrefix/tokens.txt', '$cachePrefix-tokens.txt');
    // Both zh-14M and en-20M were exported with the
    // `pruned_transducer_stateless7_streaming` icefall recipe — that's the
    // original zipformer (v1), not zipformer2. Passing 'zipformer2' here
    // mismatches model parameter shapes and crashes native code.
    _sherpa = so.OnlineRecognizer(so.OnlineRecognizerConfig(
      model: so.OnlineModelConfig(
        transducer: so.OnlineTransducerModelConfig(
          encoder: encoder, decoder: decoder, joiner: joiner,
        ),
        tokens: tokens,
        modelType: 'zipformer',
        numThreads: 2,
      ),
      decodingMethod: 'greedy_search',
      enableEndpoint: true,
      rule1MinTrailingSilence: 1.4,
      rule2MinTrailingSilence: 0.6,
      rule3MinUtteranceLength: 20,
    ));
  }

  // Japanese single-lang: Moonshine v2 (offline) gated by Silero VAD endpoints.
  // No live partials — each VAD segment finalize emits one card.
  Future<void> _loadSherpaJaOfflineWithVad() async {
    final encoder = await _copyAssetToFile(
        'assets/models/ja/encoder.ort', 'sh-ja-encoder.ort');
    final merged = await _copyAssetToFile(
        'assets/models/ja/decoder_merged.ort', 'sh-ja-decoder_merged.ort');
    final tokens = await _copyAssetToFile(
        'assets/models/ja/tokens.txt', 'sh-ja-tokens.txt');
    final vadModel = await _copyAssetToFile(
        'assets/models/vad/silero_vad.onnx', 'sh-vad-silero.onnx');
    _sherpaOffline = so.OfflineRecognizer(so.OfflineRecognizerConfig(
      model: so.OfflineModelConfig(
        moonshine: so.OfflineMoonshineModelConfig(
          encoder: encoder, mergedDecoder: merged,
        ),
        tokens: tokens,
        numThreads: 2,
        modelType: 'moonshine',
      ),
      decodingMethod: 'greedy_search',
    ));
    _vad = so.VoiceActivityDetector(
      config: so.VadModelConfig(
        sileroVad: so.SileroVadModelConfig(
          model: vadModel,
          threshold: 0.5,
          minSilenceDuration: 0.4,
          minSpeechDuration: 0.25,
          maxSpeechDuration: 12.0,
        ),
        numThreads: 1,
        debug: false,
      ),
      bufferSizeInSeconds: 30.0,
    );
  }

  Future<void> _startSherpaListening() async {
    setState(() => _status = 'Loading model...');
    final ok = await _ensureSherpa();
    if (!ok) {
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
    final modelKey = _sherpaModelKey ?? 'multi';
    final isJaOffline = modelKey == 'ja-single';
    if (!isJaOffline) {
      _sherpaStream = _sherpa!.createStream();
    }
    _sherpaLastEmitted = '';
    _sherpaLastTranslateAt = 0;
    _sherpaSegmentPcm.clear();
    try { _vad?.clear(); } catch (_) {}

    final audioStream = await _recorder.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      bitRate: 256000,
    ));

    _sessionStartedAt = DateTime.now();
    _sessionId = 'sess_${_sessionStartedAt!.millisecondsSinceEpoch}';
    await _audioWriter.start(sessionId: _sessionId!);

    _sherpaAudioSub = audioStream.listen(
      isJaOffline ? _onSherpaJaAudio : _onSherpaAudio,
    );

    _sessionStartTranscriptCount = _transcripts.length;
    final label = switch (modelKey) {
      'zh-single' => 'sherpa-onnx zh-14M',
      'en-single' => 'sherpa-onnx en-20M',
      'ja-single' => 'sherpa-onnx ja moonshine + VAD',
      _ => 'sherpa-onnx 8-lang',
    };
    setState(() {
      _isListening = true;
      _status = 'Listening ($label)';
      _liveText = '';
      _liveTranslation = '';
    });
    _pulseController.repeat(reverse: true);
    WakelockPlus.enable();
  }

  // Japanese single-lang path: feed PCM into VAD; when a speech segment closes,
  // run the offline Moonshine recognizer on it and emit one final card.
  void _onSherpaJaAudio(Uint8List data) {
    _audioWriter.write(data);
    final vad = _vad;
    final rec = _sherpaOffline;
    if (vad == null || rec == null) return;
    final bytes = Uint8List.fromList(data);
    final int16 = Int16List.view(bytes.buffer);
    final samples = Float32List(int16.length);
    for (var i = 0; i < int16.length; i++) {
      samples[i] = int16[i] / 32768.0;
    }
    try {
      vad.acceptWaveform(samples);
    } catch (e) {
      debugPrint('vad accept: $e');
      return;
    }
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      if (seg.samples.isEmpty) continue;
      try {
        final stream = rec.createStream();
        stream.acceptWaveform(samples: seg.samples, sampleRate: 16000);
        rec.decode(stream);
        final text = rec.getResult(stream).text.trim();
        stream.free();
        if (text.isNotEmpty) {
          final entryId = DateTime.now().millisecondsSinceEpoch.toString();
          _emitSherpaFinal(text, entryId: entryId);
        }
      } catch (e) {
        debugPrint('ja offline recognize: $e');
      }
    }
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
        // sherpa-single is "local only" — skip Dashscope cloud upgrade.
        if (!_isSherpaSingle) {
          _runSecondaryRecognize(segmentPcm, entryId, localText: localText);
        }
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
    if (_sherpaModelKey == 'ja-single') {
      // Drain any final VAD segment(s) before tearing down.
      try {
        final vad = _vad;
        final rec = _sherpaOffline;
        if (vad != null && rec != null) {
          while (!vad.isEmpty()) {
            final seg = vad.front();
            vad.pop();
            if (seg.samples.isEmpty) continue;
            try {
              final st = rec.createStream();
              st.acceptWaveform(samples: seg.samples, sampleRate: 16000);
              rec.decode(st);
              final text = rec.getResult(st).text.trim();
              st.free();
              if (text.isNotEmpty) {
                _emitSherpaFinal(
                  text,
                  entryId: DateTime.now().millisecondsSinceEpoch.toString(),
                );
              }
            } catch (e) {
              debugPrint('ja drain recognize: $e');
            }
          }
        }
      } catch (_) {}
      _sherpaSegmentPcm.clear();
      return;
    }
    // Streaming path (multi / zh-single / en-single): flush trailing audio so
    // the recognizer finalizes whatever's still in flight.
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
        if (!_isSherpaSingle) {
          _runSecondaryRecognize(segmentPcm, entryId, localText: localText);
        }
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
                    // Pre-warm sherpa-onnx so the first Start tap doesn't
                    // pay the model load cost. _ensureSherpa picks the right
                    // bundle (multi-stream vs single-lang) and swaps if the
                    // current bundle doesn't match.
                    final eng = _servers[v].engine;
                    if (eng == 'sherpa' || eng == 'sherpa-single') {
                      _ensureSherpa();
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
