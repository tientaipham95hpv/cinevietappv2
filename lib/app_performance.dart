import 'package:flutter/foundation.dart';

class AppPerformance {
  const AppPerformance._();

  static void logSlow(
    String operation,
    DateTime startedAt, {
    int thresholdMs = 800,
  }) {
    if (!kDebugMode) return;
    final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
    if (elapsed >= thresholdMs) {
      debugPrint('CineViet slow $operation: ${elapsed}ms');
    }
  }
}
