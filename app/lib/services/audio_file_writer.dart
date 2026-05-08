import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Bridges to the iOS-native [AudioFileWriter] (Swift, AVAudioFile + AAC).
/// Streams 16kHz mono Int16 LE PCM bytes to disk as a playable m4a so the
/// recording archive page can offer playback.
class AudioFileWriter {
  static const _channel = MethodChannel('app.translate/audio_writer');

  String? _activePath;
  String? get activePath => _activePath;
  bool get isActive => _activePath != null;

  /// Allocate a fresh m4a file under the app's `recordings/` directory and
  /// open the encoder. Returns the absolute file path on success, or null
  /// if startup failed (in which case the caller proceeds without recording).
  Future<String?> start({required String sessionId}) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final outDir = Directory('${dir.path}/recordings');
      if (!await outDir.exists()) await outDir.create(recursive: true);
      final path = '${outDir.path}/$sessionId.m4a';
      await _channel.invokeMethod<bool>('start', {'path': path});
      _activePath = path;
      return path;
    } catch (e) {
      // Encoder unavailable (older iOS / mis-config); silently skip recording.
      _activePath = null;
      return null;
    }
  }

  /// Append PCM bytes to the active file. No-op when not started.
  Future<void> write(Uint8List pcm) async {
    if (_activePath == null || pcm.isEmpty) return;
    try {
      await _channel.invokeMethod('write', {'data': pcm});
    } catch (_) {
      // Ignore individual write failures — the encoder will close cleanly
      // on stop and we still keep whatever it captured up to that point.
    }
  }

  /// Finalize the m4a (writes the moov atom). Returns the path, or null if
  /// nothing was recorded.
  Future<String?> stop() async {
    final path = _activePath;
    _activePath = null;
    if (path == null) return null;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
    // Treat empty/missing files as "no recording" so the session won't claim
    // it has audio when it doesn't.
    try {
      final f = File(path);
      if (await f.exists() && await f.length() > 1024) return path;
      if (await f.exists()) await f.delete();
    } catch (_) {}
    return null;
  }
}
