import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/recording.dart';

/// Persists recording session metadata to a single JSON file in the app's
/// documents directory. Audio blobs (when later phases add them) live in a
/// sibling `recordings/` folder; this store only owns the metadata index.
class RecordingStore extends ChangeNotifier {
  static final RecordingStore instance = RecordingStore._();
  RecordingStore._();

  List<RecordingSession> _sessions = [];
  bool _loaded = false;
  Future<void>? _loading;

  List<RecordingSession> get sessions => List.unmodifiable(_sessions);
  bool get loaded => _loaded;

  Future<void> ensureLoaded() {
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final f = await _indexFile();
      if (await f.exists()) {
        final raw = await f.readAsString();
        final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        _sessions = list.map(RecordingSession.fromJson).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      }
    } catch (e) {
      debugPrint('RecordingStore load: $e');
      _sessions = [];
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> add(RecordingSession s) async {
    await ensureLoaded();
    _sessions.insert(0, s);
    notifyListeners();
    await _persist();
  }

  Future<void> update(RecordingSession s) async {
    await ensureLoaded();
    final i = _sessions.indexWhere((e) => e.id == s.id);
    if (i < 0) return;
    _sessions[i] = s;
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String id) async {
    await ensureLoaded();
    final s = _sessions.firstWhere((e) => e.id == id, orElse: () => _sessions.first);
    _sessions.removeWhere((e) => e.id == id);
    notifyListeners();
    if (s.audioPath != null) {
      try { await File(s.audioPath!).delete(); } catch (_) {}
    }
    await _persist();
  }

  Future<File> _indexFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/recordings.json');
  }

  Future<void> _persist() async {
    try {
      final f = await _indexFile();
      final json = jsonEncode(_sessions.map((s) => s.toJson()).toList());
      await f.writeAsString(json, flush: true);
    } catch (e) {
      debugPrint('RecordingStore persist: $e');
    }
  }
}
