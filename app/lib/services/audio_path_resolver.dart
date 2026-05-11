import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// 把 `RecordingSession.audioPath` 解析成当前可用的绝对路径。
///
/// 兼容历史数据：早期版本把绝对路径
/// `/var/mobile/Containers/Data/Application/<UUID>/Documents/recordings/xxx.m4a`
/// 写进 JSON，重装 app 后 UUID 改变这条路径就失效了。这里按 basename 重新到
/// 当前 Documents 目录下找。
class AudioPathResolver {
  /// 返回当前可访问的绝对文件路径，找不到返回 null。
  static Future<String?> resolve(String? raw) async {
    if (raw == null || raw.isEmpty) return null;
    // 如果存的值已经是当前可用的绝对路径，直接返回。
    if (raw.startsWith('/') && await File(raw).exists()) return raw;
    final dir = await getApplicationDocumentsDirectory();
    // 算出相对路径（recordings/xxx.m4a）。
    String relPath;
    final marker = '/recordings/';
    final i = raw.lastIndexOf(marker);
    if (i >= 0) {
      relPath = raw.substring(i + 1); // 去掉前缀斜杠
    } else if (raw.startsWith('recordings/')) {
      relPath = raw;
    } else {
      relPath = 'recordings/${raw.split('/').last}';
    }
    final candidate = '${dir.path}/$relPath';
    if (await File(candidate).exists()) return candidate;
    return null;
  }

  /// 反向：把绝对路径压缩成相对路径（写入 JSON 时用）。
  static String toRelative(String absPath) {
    final marker = '/recordings/';
    final i = absPath.lastIndexOf(marker);
    if (i >= 0) return absPath.substring(i + 1);
    return 'recordings/${absPath.split('/').last}';
  }
}
