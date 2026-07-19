/// StreamableHTTP Origin (DNS-rebinding) protection tests.
///
/// MCP 2025-11-25 requires the Streamable HTTP transport to reject a request
/// carrying an invalid `Origin` header with HTTP 403 Forbidden. Enforcement is
/// opt-in via `StreamableHttpServerConfig.allowedOrigins`:
/// - null (default): no enforcement (prior behavior preserved);
/// - non-null: an `Origin` present but not allow-listed → 403; absent Origin
///   or allow-listed Origin → proceeds.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

Server _attachServer(StreamableHttpServerTransport transport) {
  final server = Server(
    name: 'origin-test-fixture',
    version: '1.0.0',
    capabilities: ServerCapabilities.simple(tools: true),
  );
  server.connect(transport);
  return server;
}

Future<HttpClientResponse> _send(
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
        'clientInfo': {'name': 'origin-test', 'version': '1.0.0'},
      },
    };

void main() {
  group('StreamableHTTP Origin protection', () {
    late HttpClient httpClient;

    setUp(() {
      httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 1);
    });

    tearDown(() async {
      httpClient.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test('disallowed Origin rejected with 403', () async {
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: 8520,
          isJsonResponseEnabled: true,
          allowedOrigins: ['http://localhost:8520'],
        ),
      );
      final server = _attachServer(transport);
      try {
        await transport.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final response = await _send(
          httpClient,
          Uri.parse('http://localhost:8520/mcp'),
          headers: {'Origin': 'http://evil.example.com'},
          body: _initBody(),
        );

        expect(response.statusCode, equals(403));
        final responseBody = await utf8.decoder.bind(response).join();
        final responseJson = jsonDecode(responseBody) as Map<String, dynamic>;
        expect(responseJson['error'], contains('Forbidden'));
      } finally {
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });

    test('allow-listed Origin proceeds (not 403)', () async {
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: 8521,
          isJsonResponseEnabled: true,
          allowedOrigins: ['http://localhost:8521'],
        ),
      );
      final server = _attachServer(transport);
      try {
        await transport.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final response = await _send(
          httpClient,
          Uri.parse('http://localhost:8521/mcp'),
          headers: {'Origin': 'http://localhost:8521'},
          body: _initBody(),
        );

        expect(response.statusCode, isNot(equals(403)));
        await response.drain<void>();
      } finally {
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });

    test('absent Origin header proceeds (non-browser client)', () async {
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: 8522,
          isJsonResponseEnabled: true,
          allowedOrigins: ['http://localhost:8522'],
        ),
      );
      final server = _attachServer(transport);
      try {
        await transport.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final response = await _send(
          httpClient,
          Uri.parse('http://localhost:8522/mcp'),
          body: _initBody(),
        );

        expect(response.statusCode, isNot(equals(403)));
        await response.drain<void>();
      } finally {
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });

    test('no enforcement when allowedOrigins is null (default)', () async {
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: 8523,
          isJsonResponseEnabled: true,
        ),
      );
      final server = _attachServer(transport);
      try {
        await transport.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final response = await _send(
          httpClient,
          Uri.parse('http://localhost:8523/mcp'),
          headers: {'Origin': 'http://any.example.com'},
          body: _initBody(),
        );

        expect(response.statusCode, isNot(equals(403)));
        await response.drain<void>();
      } finally {
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });
  });
}
