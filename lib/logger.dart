// Re-export logging package
export 'package:logging/logging.dart';

import 'dart:async';
import 'dart:io';
import 'package:logging/logging.dart';

// Extension methods for backward compatibility
extension LoggerExtensions on Logger {
  void debug(String message) => fine(message);
  void error(String message) => severe(message);
  void warn(String message) => warning(message);
}

/// Active subscription for the stderr log sink (see [attachStderrLogSink]).
StreamSubscription<LogRecord>? _stderrLogSub;

/// Route all log records to **stderr** so a stdio-based MCP host cannot have
/// its stdout — which carries the protocol JSON-RPC stream — corrupted by log
/// output. Opt-in and idempotent: call it once during startup on the stdio
/// transport. 2025-11-25 clarifies servers may emit logs at any level to
/// stderr on the stdio transport.
///
/// Existing behavior is unchanged unless this is called: the `logging`
/// framework prints nothing by default, so servers that never attached a
/// listener are unaffected, and this replaces only the sink installed by a
/// prior call to this function (any independent `Logger.root.onRecord`
/// listeners are left in place).
///
/// Pass [level] to also set `Logger.root.level` in the same call.
StreamSubscription<LogRecord> attachStderrLogSink({Level? level}) {
  if (level != null) {
    Logger.root.level = level;
  }
  _stderrLogSub?.cancel();
  final sub = Logger.root.onRecord.listen((record) {
    stderr.writeln(
        '[${record.level.name}] ${record.time.toIso8601String()} '
        '${record.loggerName}: ${record.message}');
    if (record.error != null) {
      stderr.writeln('  error: ${record.error}');
    }
    if (record.stackTrace != null) {
      stderr.writeln('  stack: ${record.stackTrace}');
    }
  });
  _stderrLogSub = sub;
  return sub;
}

/// Remove the stderr log sink installed by [attachStderrLogSink]. Safe to
/// call when no sink is attached.
Future<void> detachStderrLogSink() async {
  await _stderrLogSub?.cancel();
  _stderrLogSub = null;
}
