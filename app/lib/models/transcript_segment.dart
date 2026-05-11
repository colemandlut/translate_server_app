/// 整段重识别的一个 word/字符。begin/end 以毫秒为单位，相对录音起点。
class TranscriptWord {
  final int? beginMs;
  final int? endMs;
  final String text;

  TranscriptWord({
    required this.beginMs,
    required this.endMs,
    required this.text,
  });

  Map<String, dynamic> toJson() => {
        'beginMs': beginMs,
        'endMs': endMs,
        'text': text,
      };

  factory TranscriptWord.fromJson(Map<String, dynamic> json) {
    return TranscriptWord(
      beginMs: json['beginMs'] as int?,
      endMs: json['endMs'] as int?,
      text: (json['text'] as String?) ?? '',
    );
  }
}

/// 整段重识别的一句字幕。begin/end 以毫秒为单位，相对录音起点。
class TranscriptSegment {
  final int? beginMs;
  final int? endMs;
  final String text;
  final String translated;
  final String spokenLang;
  final String translatedLang;
  // 字级别时间戳；如果 Dashscope 没返回 words 数组则为空。
  final List<TranscriptWord> words;

  TranscriptSegment({
    required this.beginMs,
    required this.endMs,
    required this.text,
    required this.translated,
    required this.spokenLang,
    required this.translatedLang,
    this.words = const [],
  });

  Map<String, dynamic> toJson() => {
        'beginMs': beginMs,
        'endMs': endMs,
        'text': text,
        'translated': translated,
        'spokenLang': spokenLang,
        'translatedLang': translatedLang,
        'words': words.map((w) => w.toJson()).toList(),
      };

  factory TranscriptSegment.fromJson(Map<String, dynamic> json) {
    return TranscriptSegment(
      beginMs: json['beginMs'] as int?,
      endMs: json['endMs'] as int?,
      text: (json['text'] as String?) ?? '',
      translated: (json['translated'] as String?) ?? '',
      spokenLang: (json['spokenLang'] as String?) ?? '',
      translatedLang: (json['translatedLang'] as String?) ?? '',
      words: (json['words'] as List?)
              ?.map((e) => TranscriptWord.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }
}
