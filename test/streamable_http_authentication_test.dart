/// StreamableHTTP Authentication Tests - Essential Security Verification
///
/// Core tests to verify Bearer token authentication works correctly
/// and maintains security compliance with MCP standards.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

/// Boots a real `Server` on top of the supplied transport so that requests
/// which clear the auth gate produce a real JSON-RPC response. Without this
/// wiring the POST handler would queue the message and block forever
/// waiting for an application to respond, which made the original tests
/// hang indefinitely.
Server _attachServer(StreamableHttpServerTransport transport) {
  final server = Server(
    name: 'auth-test-fixture',
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
  // Cap response wait time so a regression in the auth gate cannot freeze
  // the suite — the gate fires synchronously on the request, well under 5s.
  return request.close().timeout(const Duration(seconds: 5));
}

void main() {
  group('StreamableHTTP Authentication', () {
    late HttpClient httpClient;

    setUp(() {
      httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 1);
    });

    tearDown(() async {
      httpClient.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test('Valid Bearer token accepted', () async {
      const authToken = 'valid-test-token-123';

      final transport = StreamableHttpServerTransport(
        config: StreamableHttpServerConfig(
          port: 8500,
          authToken: authToken,
          isJsonResponseEnabled: true,
        ),
      );
      final server = _attachServer(transport);

      try {
        await transport.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final response = await _send(
          httpClient,
          Uri.parse('http://localhost:8500/mcp'),
          headers: {
            'Authorization': 'Bearer $authToken',
            'mcp-session-id': 'test-session',
          },
          body: {
            'jsonrpc': '2.0',
            'method': 'initialize',
            'id': 1,
            'params': {
              'protocolVersion': '2025-11-25',
              'capabilities': <String, Object?>{},
              'clientInfo': {'name': 'auth-test', 'version': '1.0.0'},
            },
          },
        );

        // Auth gate cleared — the server actually answered.
        expect(response.statusCode, equals(200));
        await response.drain<void>();
      } finally {
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });

    test('Invalid Bearer token rejected with 401', () async {
      const authToken = 'valid-token-123';
      const invalidToken = 'invalid-token-456';

      final transport = StreamableHttpServerTransport(
        config: StreamableHttpServerConfig(
          port: 8501,
          authToken: authToken,
          isJsonResponseEnabled: true,
        ),
      );
      final server = _attachServer(transport);

      try {
        await transport.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final response = await _send(
          httpClient,
          Uri.parse('http://localhost:8501/mcp'),
          headers: {
            'Authorization': 'Bearer $invalidToken',
            'mcp-session-id': 'test-session',
          },
          body: {'jsonrpc': '2.0', 'method': 'initialize', 'id': 1},
        );

        expect(response.statusCode, equals(401));

        final responseBody = await utf8.decoder.bind(response).join();
        final responseJson = jsonDecode(responseBody) as Map<String, dynamic>;
        expect(responseJson['error'], contains('Unauthorized'));
      } finally {
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });

    test('Missing Authorization header rejected with 401', () async {
      const authToken = 'valid-token-123';

      final transport = StreamableHttpServerTransport(
        config: StreamableHttpServerConfig(
          port: 8502,
          authToken: authToken,
          isJsonResponseEnabled: true,
        ),
      );
      final server = _attachServer(transport);

      try {
        await transport.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final response = await _send(
          httpClient,
          Uri.parse('http://localhost:8502/mcp'),
          headers: {'mcp-session-id': 'test-session'},
          body: {'jsonrpc': '2.0', 'method': 'initialize', 'id': 1},
        );

        expect(response.statusCode, equals(401));
        await response.drain<void>();
      } finally {
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });

    test('Auth disabled mode allows requests', () async {
      final transport = StreamableHttpServerTransport(
        config: StreamableHttpServerConfig(
          port: 8503,
          authToken: null, // Auth disabled
          isJsonResponseEnabled: true,
        ),
      );
      final server = _attachServer(transport);

      try {
        await transport.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final response = await _send(
          httpClient,
          Uri.parse('http://localhost:8503/mcp'),
          headers: {'mcp-session-id': 'test-session'},
          body: {
            'jsonrpc': '2.0',
            'method': 'initialize',
            'id': 1,
            'params': {
              'protocolVersion': '2025-11-25',
              'capabilities': <String, Object?>{},
              'clientInfo': {'name': 'auth-test', 'version': '1.0.0'},
            },
          },
        );

        expect(response.statusCode, equals(200));
        await response.drain<void>();
      } finally {
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });

    test('Factory method supports authToken', () {
      final transportResult = McpServer.createStreamableHttpTransport(
        8504,
        authToken: 'factory-test-token',
        isJsonResponseEnabled: true,
      );

      expect(transportResult.isSuccess, isTrue);

      final transport = transportResult.get();
      expect(transport.config.authToken, equals('factory-test-token'));

      transport.close();
    });

    test('Token validation logic is consistent', () async {
      const validToken = 'consistency-token-123';
      const invalidToken = 'wrong-token-456';

      final transport = StreamableHttpServerTransport(
        config: StreamableHttpServerConfig(
          port: 8505,
          authToken: validToken,
          isJsonResponseEnabled: true,
        ),
      );
      final server = _attachServer(transport);

      try {
        await transport.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final invalidResponse = await _send(
          httpClient,
          Uri.parse('http://localhost:8505/mcp'),
          headers: {
            'Authorization': 'Bearer $invalidToken',
            'mcp-session-id': 'test-session',
          },
          body: {'jsonrpc': '2.0', 'method': 'initialize', 'id': 1},
        );

        expect(invalidResponse.statusCode, equals(401));

        final invalidBody = await utf8.decoder.bind(invalidResponse).join();
        final invalidJson = jsonDecode(invalidBody) as Map<String, dynamic>;
        expect(invalidJson['error'], contains('Unauthorized'));

        final validResponse = await _send(
          httpClient,
          Uri.parse('http://localhost:8505/mcp'),
          headers: {
            'Authorization': 'Bearer $validToken',
            'mcp-session-id': 'test-session-2',
          },
          body: {
            'jsonrpc': '2.0',
            'method': 'initialize',
            'id': 1,
            'params': {
              'protocolVersion': '2025-11-25',
              'capabilities': <String, Object?>{},
              'clientInfo': {'name': 'auth-test', 'version': '1.0.0'},
            },
          },
        );

        expect(validResponse.statusCode, equals(200));
        await validResponse.drain<void>();
      } finally {
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });
  });
}
