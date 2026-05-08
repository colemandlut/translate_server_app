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

  Map<String, dynamic> toJson() => {
        'id': id,
        'original': original,
        'translated': translated,
        'spokenLang': spokenLang,
        'translatedLang': translatedLang,
      };

  factory TranscriptEntry.fromJson(Map<String, dynamic> json) {
    return TranscriptEntry(
      id: json['id'] as String,
      original: (json['original'] as String?) ?? '',
      translated: (json['translated'] as String?) ?? '',
      spokenLang: (json['spokenLang'] as String?) ?? '',
      translatedLang: (json['translatedLang'] as String?) ?? '',
    );
  }
}
