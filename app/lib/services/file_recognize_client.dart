import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/transcript_segment.dart';

class FileRecognizeException implements Exception {
  final int statusCode;
  final String body;
  FileRecognizeException(this.statusCode, this.body);
  @override
  String toString() => 'FileRecognizeException($statusCode): $body';
}

class FileRecognizeResult {
  final String overallText;
  final String overallTranslated;
  final String lang;
  final List<TranscriptSegment> segments;
  FileRecognizeResult(
      this.overallText, this.overallTranslated, this.lang, this.segments);
}

class FileRecognizeClient {
  static const _endpoint =
      'https://translate-relay-dashscope.fly.dev/file-recognize';

  Future<FileRecognizeResult> run({
    required String audioPath,
    required String langA,
    required String langB,
    Duration timeout = const Duration(seconds: 150),
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse(_endpoint))
      ..fields['langA'] = langA
      ..fields['langB'] = langB
      ..files.add(await http.MultipartFile.fromPath('audio', audioPath));
    final streamed = await req.send().timeout(timeout);
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode != 200) {
      throw FileRecognizeException(resp.statusCode, resp.body);
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final segs = (json['segments'] as List?)
            ?.map((e) =>
                TranscriptSegment.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <TranscriptSegment>[];
    return FileRecognizeResult(
      (json['overallText'] as String?) ?? '',
      (json['overallTranslated'] as String?) ?? '',
      (json['lang'] as String?) ?? '',
      segs,
    );
  }
}
