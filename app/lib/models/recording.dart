import 'transcript_entry.dart';
import 'transcript_segment.dart';

class RecordingSession {
  final String id;
  final DateTime createdAt;
  final String? audioPath; // null until P2 ships m4a writer
  final List<TranscriptEntry> liveTranscripts;
  final String langA;
  final String langB;
  final String serverName;
  final Duration duration;
  // Tab 2/3 outputs, filled in by later phases. Persisted so a re-recognize
  // result survives an app restart.
  final String? overallText;
  final String? overallTranslated;
  // 整段重识别按 VAD 切出的句子级字幕。可能为 null（老会话或服务端没返回）；
  // null 时 UI 回退到 overallText/overallTranslated 简单两栏。
  final List<TranscriptSegment>? overallSegments;
  final String? llmSummary;

  RecordingSession({
    required this.id,
    required this.createdAt,
    required this.audioPath,
    required this.liveTranscripts,
    required this.langA,
    required this.langB,
    required this.serverName,
    required this.duration,
    this.overallText,
    this.overallTranslated,
    this.overallSegments,
    this.llmSummary,
  });

  RecordingSession copyWith({
    String? audioPath,
    String? overallText,
    String? overallTranslated,
    List<TranscriptSegment>? overallSegments,
    String? llmSummary,
  }) {
    return RecordingSession(
      id: id,
      createdAt: createdAt,
      audioPath: audioPath ?? this.audioPath,
      liveTranscripts: liveTranscripts,
      langA: langA,
      langB: langB,
      serverName: serverName,
      duration: duration,
      overallText: overallText ?? this.overallText,
      overallTranslated: overallTranslated ?? this.overallTranslated,
      overallSegments: overallSegments ?? this.overallSegments,
      llmSummary: llmSummary ?? this.llmSummary,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'audioPath': audioPath,
        'liveTranscripts': liveTranscripts.map((e) => e.toJson()).toList(),
        'langA': langA,
        'langB': langB,
        'serverName': serverName,
        'durationMs': duration.inMilliseconds,
        'overallText': overallText,
        'overallTranslated': overallTranslated,
        'overallSegments': overallSegments?.map((e) => e.toJson()).toList(),
        'llmSummary': llmSummary,
      };

  factory RecordingSession.fromJson(Map<String, dynamic> json) {
    return RecordingSession(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      audioPath: json['audioPath'] as String?,
      liveTranscripts: (json['liveTranscripts'] as List)
          .map((e) => TranscriptEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      langA: json['langA'] as String,
      langB: json['langB'] as String,
      serverName: json['serverName'] as String,
      duration: Duration(milliseconds: json['durationMs'] as int),
      overallText: json['overallText'] as String?,
      overallTranslated: json['overallTranslated'] as String?,
      overallSegments: (json['overallSegments'] as List?)
          ?.map((e) => TranscriptSegment.fromJson(e as Map<String, dynamic>))
          .toList(),
      llmSummary: json['llmSummary'] as String?,
    );
  }
}
