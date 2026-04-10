import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'models/language.dart';

const _defaultServerUrl = 'ws://192.168.5.59:8080';

class TranscriptEntry {
  final String id;
  final String original;
  final String translated;
  final String spokenLang;
  final String translatedLang;

  TranscriptEntry({
    required this.id,
    required this.original,
    required this.translated,
    required this.spokenLang,
    required this.translatedLang,
  });
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  bool _isListening = false;
  Language _langA = languages[2]; // English
  Language _langB = languages[0]; // Chinese
  final List<TranscriptEntry> _transcripts = [];
  String _liveText = '';
  String _liveTranslation = '';
  String _status = 'Ready';
  String _serverUrl = _defaultServerUrl;

  final _recorder = AudioRecorder();
  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSub;
  StreamSubscription? _audioSub;

  final _scrollController = ScrollController();
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  bool _opusInitialized = false;

  @override
  void initState() {
    super.initState();
    _initOpus();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1400),
      vsync: this,
    );
    _pulseAnimation = Tween(begin: 1.0, end: 1.5).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _stop();
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ---- WebSocket + Recording ----

  Future<void> _start() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _showAlert('Permission Required', 'Microphone permission is needed.');
      return;
    }

    setState(() {
      _isListening = true;
      _status = 'Connecting...';
      _liveText = '';

    });
    _pulseController.repeat(reverse: true);

    try {
      // Connect WebSocket
      _wsChannel = WebSocketChannel.connect(Uri.parse(_serverUrl));
      await _wsChannel!.ready;

      // Send start command
      _wsChannel!.sink.add(jsonEncode({
        'type': 'start',
        'langA': _langA.code,
        'langB': _langB.code,
      }));

      // Listen for server messages
      _wsSub = _wsChannel!.stream.listen(
        (data) => _handleServerMessage(data),
        onError: (err) {
          debugPrint('WS error: $err');
          if (_isListening) {
            setState(() => _status = 'Connection error');
            _stop();
          }
        },
        onDone: () {
          debugPrint('WS closed');
          if (_isListening) _stop();
        },
      );

      // Opus encoder
      final encoder = SimpleOpusEncoder(
        sampleRate: 16000,
        channels: 1,
        application: Application.voip,
      );

      // Start recording raw PCM audio
      final audioStream = await _recorder.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 256000,
      ));

      // Opus frame = 20ms = 640 bytes (16kHz * 16bit * 1ch * 0.02s)
      const frameSizeBytes = 640;
      List<int> pcmBuffer = [];

      _audioSub = audioStream.listen((data) {
        pcmBuffer.addAll(data);

        // Encode and send every 20ms Opus frame immediately
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

      setState(() => _status = 'Listening...');
    } catch (e) {
      debugPrint('Start error: $e');
      setState(() {
        _isListening = false;
        _status = 'Error: $e';
      });
      _pulseController.stop();
      _pulseController.reset();
    }
  }

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
        // Real-time translation of interim text
        setState(() {
          _liveText = msg['text'] as String? ?? '';
          _liveTranslation = msg['translated'] as String? ?? '';
        });
        _scrollToBottom();
      } else if (type == 'final') {
        final text = msg['text'] as String? ?? '';
        final translated = msg['translated'] as String? ?? '';
        final spokenLang = msg['spokenLang'] as String? ?? '';
        final translatedLang = msg['translatedLang'] as String? ?? '';

        setState(() {
          _liveText = '';
          _liveTranslation = '';
          _transcripts.add(TranscriptEntry(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            original: text,
            translated: translated,
            spokenLang: spokenLang,
            translatedLang: translatedLang,
          ));
        });
        _scrollToBottom();
      }
    } catch (e) {
      debugPrint('Parse error: $e');
    }
  }

  Future<void> _stop() async {
    _isListening = false;
    _pulseController.stop();
    _pulseController.reset();

    _audioSub?.cancel();
    _audioSub = null;

    try {
      await _recorder.stop();
    } catch (_) {}

    // Send stop command
    if (_wsChannel != null) {
      try {
        _wsChannel!.sink.add(jsonEncode({'type': 'stop'}));
        await _wsChannel!.sink.close();
      } catch (_) {}
    }
    _wsSub?.cancel();
    _wsSub = null;
    _wsChannel = null;

    setState(() {
      _isListening = false;
      _status = 'Stopped';
      _liveText = '';
      _liveTranslation = '';
    });
  }

  void _swapLanguages() {
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
    final controller = TextEditingController(text: _serverUrl);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF16213e),
        title: const Text('Server URL',
            style: TextStyle(color: Color(0xFFe0e0ff))),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Color(0xFFe0e0ff)),
          decoration: const InputDecoration(
            hintText: 'ws://hostname:8080',
            hintStyle: TextStyle(color: Color(0xFF7f8fa6)),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              setState(() => _serverUrl = controller.text.trim());
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
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

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
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
                  const Expanded(
                    child: Text('Real-time Translator',
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFe0e0ff))),
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
                          child: Text('<->',
                              style: TextStyle(
                                  color: Color(0xFF53a8ff),
                                  fontSize: 18,
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

            // Transcript list
            Expanded(
              child: ListView(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                children: [
                  if (_transcripts.isEmpty &&
                      _liveText.isEmpty &&
                      !_isListening)
                    const Padding(
                      padding: EdgeInsets.only(top: 100),
                      child: Text(
                        'Speak in either language\nauto-detect & translate',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Color(0xFF7f8fa6), fontSize: 16),
                      ),
                    ),
                  ..._transcripts.map(_buildEntry),
                  if (_liveText.isNotEmpty) _buildLive(),
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
                        color: const Color(0xFF7f8fa6),
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
                      onPressed: _isListening ? _stop : _start,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isListening
                            ? const Color(0xFFe74c3c)
                            : const Color(0xFF4ecca3),
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
                              : const Color(0xFF1a1a2e),
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
