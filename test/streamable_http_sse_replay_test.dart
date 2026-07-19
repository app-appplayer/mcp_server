/// StreamableHTTP SSE resumability / event replay tests (SEP-1699, 2025-11-25).
///
/// When a client reconnects a session's standalone GET SSE stream with a
/// `Last-Event-ID`, the server replays every stored GET-stream event for that
/// session with a numeric id greater than the given one, in id order, then
/// keeps the stream open for live events.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

Server _boot(StreamableHttpServerTransport transport) {
  final server = Server(
    name: 'sse-replay-fixture',
    version: '1.0.0',
    capabilities: ServerCapabilities.simple(tools: true),
  );
  server.connect(transport);
  return server;
}

Future<HttpClientResponse> _post(
  HttpClient httpClient,
  Uri uri, {
  Map<String, String> headers = const {},
  required Map<String, Object?> body,
}) async {
  final request = await httpClient.postUrl(uri);
  request.headers.set('Content-Type', 'application/json');
  request.headers.set('Accept', 'application/json, text/event-stream');
  headers.forEach(request.headers.set);
  request.write(jsonEncode(body));
  return request.close().timeout(const Duration(seconds: 5));
}

Map<String, Object?> _initBody() => {
      'jsonrpc': '2.0',
      'method': 'initialize',
      'id': 1,
      'params': {
        'protocolVersion': '2025-11-25',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'sse-replay-test', 'version': '1.0.0'},
      },
    };

void main() {
  group('StreamableHTTP SSE replay', () {
    late HttpClient httpClient;

    setUp(() {
      httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 2);
    });

    tearDown(() async {
      httpClient.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test('reconnect with Last-Event-ID replays stored events in order',
        () async {
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: 8540,
          isJsonResponseEnabled: true,
        ),
      );
      final server = _boot(transport);
      try {
        await transport.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final uri = Uri.parse('http://localhost:8540/mcp');

        // 1) initialize → session id.
        final init = await _post(httpClient, uri, body: _initBody());
        final sessionId = init.headers.value('mcp-session-id');
        await init.drain<void>();
        expect(sessionId, isNotNull);

        // 2) emit two server-initiated log notifications. No GET stream is
        //    connected yet, so they are only buffered in the event store.
        server.sendLog(McpLogLevel.info, 'event-alpha');
        server.sendLog(McpLogLevel.info, 'event-beta');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // 3) reconnect the GET stream with Last-Event-ID: 0 → replay both.
        final getReq = await httpClient.getUrl(uri);
        getReq.headers.set('Accept', 'text/event-stream');
        getReq.headers.set('mcp-session-id', sessionId!);
        getReq.headers.set('last-event-id', '0');
        final getResp = await getReq.close().timeout(const Duration(seconds: 5));

        // 4) collect the replayed SSE frames within a short window.
        final buffer = StringBuffer();
        final done = Completer<void>();
        final sub = getResp
            .transform(utf8.decoder)
            .listen((chunk) {
          buffer.write(chunk);
          if (buffer.toString().contains('event-alpha') &&
              buffer.toString().contains('event-beta') &&
              !done.isCompleted) {
            done.complete();
          }
        });
        await done.future.timeout(const Duration(seconds: 3),
            onTimeout: () {});
        await sub.cancel();

        final text = buffer.toString();
        expect(text, contains('event-alpha'));
        expect(text, contains('event-beta'));
        // Replayed events carry their stored ids; alpha precedes beta.
        expect(text.indexOf('event-alpha'),
            lessThan(text.indexOf('event-beta')));
        expect(text, contains('id: '));
      } finally {
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });

    test('invalid Last-Event-ID rejected with 400', () async {
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: 8541,
          isJsonResponseEnabled: true,
        ),
      );
      final server = _boot(transport);
      try {
        await transport.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final uri = Uri.parse('http://localhost:8541/mcp');

        final init = await _post(httpClient, uri, body: _initBody());
        final sessionId = init.headers.value('mcp-session-id');
        await init.drain<void>();

        final getReq = await httpClient.getUrl(uri);
        getReq.headers.set('Accept', 'text/event-stream');
        getReq.headers.set('mcp-session-id', sessionId!);
        getReq.headers.set('last-event-id', 'not-a-number');
        final getResp = await getReq.close().timeout(const Duration(seconds: 5));

        expect(getResp.statusCode, equals(400));
        await getResp.drain<void>();
      } finally {
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });
  });
}
