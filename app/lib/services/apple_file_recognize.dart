import 'package:flutter/services.dart';

import '../models/transcript_segment.dart';

/// 本地整段重识别（Apple SFSpeechRecognizer on-device）。
/// Swift 实现在 Runner/AppDelegate.swift 的 AppleFileRecognizer 插件里。
class AppleFileRecognizeException implements Exception {
  final String code;
  final String message;
  AppleFileRecognizeException(this.code, this.message);
  @override
  String toString() => 'AppleFileRecognizeException($code): $message';
}

class AppleFileRecognizer {
  static const _channel = MethodChannel('app.translate/apple_file_asr');

  /// 每个 locale 的本地识别可用性：
  /// ok / no_ondevice（听写语言包未下载）/ unavailable / no_recognizer。
  Future<Map<String, String>> availability(List<String> candidates) async {
    try {
      final res = await _channel.invokeMethod<Map>(
        'availability',
        {'candidates': candidates},
      );
      return {
        for (final e in (res ?? const {}).entries)
          e.key as String: e.value as String,
      };
    } on PlatformException catch (e) {
      throw AppleFileRecognizeException(e.code, e.message ?? '');
    }
  }

  /// 截取录音开头（Swift 侧 ~10s），对每个候选 locale 各跑一遍本地识别。
  /// 返回覆盖率加权置信度最高的 locale + 按分数降序的候选序列 + 各 locale
  /// 探测失败原因（比如听写语言包没下载）。全部 0 分时 locale 为 null。
  Future<
      ({
        String? locale,
        List<String> ranked,
        Map<String, double> scores,
        Map<String, String> errors,
      })> detect(String path, List<String> candidates) async {
    try {
      final res = await _channel.invokeMethod<Map>(
        'detect',
        {'path': path, 'candidates': candidates},
      );
      final loc = res?['locale'] as String?;
      final scores = <String, double>{
        for (final e in ((res?['scores'] as Map?) ?? const {}).entries)
          e.key as String: (e.value as num).toDouble(),
      };
      final errors = <String, String>{
        for (final e in ((res?['errors'] as Map?) ?? const {}).entries)
          e.key as String: e.value as String,
      };
      final ranked = scores.keys.toList()
        ..sort((a, b) => (scores[b] ?? 0).compareTo(scores[a] ?? 0));
      return (
        locale: (loc == null || loc.isEmpty) ? null : loc,
        ranked: ranked,
        scores: scores,
        errors: errors,
      );
    } on PlatformException catch (e) {
      throw AppleFileRecognizeException(e.code, e.message ?? '');
    }
  }

  /// 整段识别，返回全文 + 词级时间戳。
  Future<({String text, List<TranscriptWord> words})> recognize(
      String path, String locale) async {
    try {
      final res = await _channel.invokeMethod<Map>(
        'recognize',
        {'path': path, 'locale': locale},
      );
      final words = ((res?['words'] as List?) ?? const [])
          .map((e) {
            final m = e as Map;
            return TranscriptWord(
              beginMs: (m['beginMs'] as num?)?.toInt(),
              endMs: (m['endMs'] as num?)?.toInt(),
              text: (m['text'] as String?) ?? '',
            );
          })
          .where((w) => w.text.isNotEmpty)
          .toList();
      return (text: (res?['text'] as String?) ?? '', words: words);
    } on PlatformException catch (e) {
      throw AppleFileRecognizeException(e.code, e.message ?? '');
    }
  }

  /// 把词级时间戳按停顿/标点切成句子卡片（对齐 Dashscope 整段重识别的
  /// segments 结构，字幕卡片 UI 直接复用）。translated 留空由调用方填。
  static List<TranscriptSegment> groupWords(
    List<TranscriptWord> words, {
    required String spokenLang,
    required String translatedLang,
    int gapMs = 800,
    int maxWordsPerSegment = 60,
  }) {
    if (words.isEmpty) return const [];
    // en 词与词之间要补空格；zh/ja 直接拼。
    final joiner = spokenLang.toLowerCase().startsWith('en') ? ' ' : '';
    bool endsSentence(String t) =>
        RegExp(r'[。？！．\.\?\!]\s*$').hasMatch(t);

    final segments = <TranscriptSegment>[];
    var current = <TranscriptWord>[];
    void flush() {
      if (current.isEmpty) return;
      segments.add(TranscriptSegment(
        beginMs: current.first.beginMs,
        endMs: current.last.endMs,
        text: current.map((w) => w.text).join(joiner).trim(),
        translated: '',
        spokenLang: spokenLang,
        translatedLang: translatedLang,
        words: List.of(current),
      ));
      current = <TranscriptWord>[];
    }

    for (final w in words) {
      if (current.isNotEmpty) {
        final prevEnd = current.last.endMs;
        final gap = (w.beginMs != null && prevEnd != null)
            ? w.beginMs! - prevEnd
            : 0;
        if (gap > gapMs ||
            current.length >= maxWordsPerSegment ||
            endsSentence(current.last.text)) {
          flush();
        }
      }
      current.add(w);
    }
    flush();
    return segments;
  }
}
