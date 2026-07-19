// Probe used by test/stderr_log_sink_test.dart.
//
// Attaches the stderr log sink, emits a log record, and writes a protocol
// line to stdout. Run as a subprocess so the test can prove that log output
// lands on stderr and never corrupts stdout (which carries JSON-RPC on the
// stdio transport).
import 'dart:io';

import 'package:mcp_server/mcp_server.dart';

Future<void> main() async {
  attachStderrLogSink(level: Level.ALL);
  // Simulated protocol frame on stdout.
  stdout.writeln('DATA_ON_STDOUT');
  Logger('probe').severe('LOG_ON_STDERR');
  // Let the broadcast stream deliver the record to the sink.
  await Future<void>.delayed(const Duration(milliseconds: 50));
  await stdout.flush();
  await stderr.flush();
  await detachStderrLogSink();
}
