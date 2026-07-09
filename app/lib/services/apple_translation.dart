import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart 侧对 iOS Translation framework 的封装（iOS 18+）。
/// Swift 实现在 Runner/AppDelegate.swift 的 AppleTranslator 插件里。
class AppleTranslation {
  static const _channel = MethodChannel('app.translate/apple_translation');

  /// 本地翻译一段文本。失败（老 iOS、语言包缺失等）返回 null。
  static Future<String?> translate(
      String text, String sourceBcp47, String targetBcp47) async {
    if (text.isEmpty) return null;
    try {
      final result = await _channel.invokeMethod<String>(
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

  /// 预热语言对：语言包没装时会弹系统下载框，装好后 resolve。
  static Future<void> prepare(String sourceBcp47, String targetBcp47) async {
    try {
      await _channel.invokeMethod<void>(
        'prepare',
        {'source': sourceBcp47, 'target': targetBcp47},
      );
    } on PlatformException catch (e) {
      debugPrint('apple prepare: ${e.code} ${e.message}');
    } catch (e) {
      debugPrint('apple prepare: $e');
    }
  }
}
