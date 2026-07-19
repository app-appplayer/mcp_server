import 'dart:io';

import 'package:mcp_server/mcp_server.dart';
import 'package:test/test.dart';

void main() {
  group('A11 stdio -> stderr logging', () {
    test('log output lands on stderr and never on stdout', () async {
      final probe = File('test/support/stderr_log_probe.dart').absolute;
      expect(probe.existsSync(), isTrue,
          reason: 'probe script must exist at ${probe.path}');

      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', probe.path],
        workingDirectory: Directory.current.path,
      );

      expect(result.exitCode, 0, reason: result.stderr.toString());
      final out = result.stdout.toString();
      final err = result.stderr.toString();

      // Protocol data must be intact on stdout.
      expect(out, contains('DATA_ON_STDOUT'));
      // Log record must NOT leak into stdout.
      expect(out, isNot(contains('LOG_ON_STDERR')));
      // Log record MUST appear on stderr.
      expect(err, contains('LOG_ON_STDERR'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('attachStderrLogSink is idempotent and detach is safe', () async {
      final sub1 = attachStderrLogSink();
      final sub2 = attachStderrLogSink();
      // Second attach replaced the first sink; canceling the stale one is a
      // no-op on the active sink.
      expect(sub1, isNot(same(sub2)));
      await detachStderrLogSink();
      // Safe to call again with no active sink.
      await detachStderrLogSink();
    });

    test('attachStderrLogSink can set the root level', () {
      final prior = Logger.root.level;
      addTearDown(() => Logger.root.level = prior);
      attachStderrLogSink(level: Level.WARNING);
      expect(Logger.root.level, Level.WARNING);
      detachStderrLogSink();
    });
  });
}
