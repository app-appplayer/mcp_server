/// Tool execution error semantics (SEP-1303, MCP 2025-11-25).
///
/// A tool handler that throws is a *tool execution error*, not a protocol
/// error. For a session that negotiated 2025-11-25 the server returns an
/// `isError: true` CallToolResult (HTTP 200) so the model can self-correct.
/// For an older negotiated version the prior JSON-RPC protocol-error behavior
/// is preserved (no breaking change).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

Server _bootThrowingToolServer(StreamableHttpServerTransport transport) {
  final server = Server(
    name: 'tool-error-fixture',
    version: '1.0.0',
    capabilities: ServerCapabilities.simple(tools: true),
  );
  server.addTool(
    name: 'boom',
    description: 'A tool that always throws',
    inputSchema: {'type': 'object'},
    handler: (args) async => throw StateError('kaboom'),
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

Map<String, Object?> _initBody(String version) => {
      'jsonrpc': '2.0',
      'method': 'initialize',
      'id': 1,
      'params': {
        'protocolVersion': version,
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'tool-error-test', 'version': '1.0.0'},
      },
    };

Map<String, Object?> _callBoom() => {
      'jsonrpc': '2.0',
      'method': 'tools/call',
      'id': 2,
      'params': {'name': 'boom', 'arguments': <String, Object?>{}},
    };

void main() {
  group('Tool execution error semantics', () {
    late HttpClient httpClient;

    setUp(() {
      httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 1);
    });

    tearDown(() async {
      httpClient.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    Future<Map<String, dynamic>> driveThrowOnce(int port, String version) async {
      final transport = StreamableHttpServerTransport(
        config: StreamableHttpServerConfig(
          port: port,
          isJsonResponseEnabled: true,
        ),
      );
      final server = _bootThrowingToolServer(transport);
      try {
        await transport.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final uri = Uri.parse('http://localhost:$port/mcp');

        // 1) initialize to set the session's negotiated version.
        final init = await _post(httpClient, uri, body: _initBody(version));
        final sessionId = init.headers.value('mcp-session-id');
        await init.drain<void>();
        expect(sessionId, isNotNull,
            reason: 'server must issue a session id on initialize');

        // 2) call the throwing tool on the same session.
        final call = await _post(
          httpClient,
          uri,
          headers: {'mcp-session-id': sessionId!},
          body: _callBoom(),
        );
        final bodyText = await utf8.decoder.bind(call).join();
        return {
          'status': call.statusCode,
          'json': jsonDecode(bodyText) as Map<String, dynamic>,
        };
      } finally {
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }

    test('2025-11-25 → isError CallToolResult (HTTP 200), not protocol error',
        () async {
      final r = await driveThrowOnce(8530, '2025-11-25');
      expect(r['status'], equals(200));
      final json = r['json'] as Map<String, dynamic>;
      // JSON-RPC success envelope carrying a tool result with isError=true.
      expect(json.containsKey('error'), isFalse,
          reason: 'must not be a JSON-RPC protocol error');
      final result = json['result'] as Map<String, dynamic>;
      expect(result['isError'], isTrue);
      final content = (result['content'] as List).cast<Map<String, dynamic>>();
      expect(content.first['text'], contains('kaboom'));
    });

    test('2025-06-18 → JSON-RPC protocol error (backward compatible)',
        () async {
      final r = await driveThrowOnce(8531, '2025-06-18');
      final json = r['json'] as Map<String, dynamic>;
      expect(json.containsKey('error'), isTrue,
          reason: 'older negotiated version keeps protocol-error behavior');
      final error = json['error'] as Map<String, dynamic>;
      expect(error['message'] ?? error.toString(), contains('Tool execution error'));
    });
  });
}
