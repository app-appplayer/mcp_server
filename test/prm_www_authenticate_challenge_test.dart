/// MCP 2025-11-25 auth stack — server side (A6 PRM 401 linkage, A7 scope).
///
/// Verifies that when OAuth Protected Resource metadata is configured
/// (`Server.configureProtectedResource`), a `401 Unauthorized` on the
/// Streamable HTTP transport carries a spec-compliant
/// `WWW-Authenticate: Bearer resource_metadata="…"` challenge (RFC 9728 /
/// SEP-985), optionally advertising a required `scope=` (SEP-835). When PRM is
/// NOT configured the prior bare-401 behavior is preserved (A6 opt-in).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

Server _attachServer(
  StreamableHttpServerTransport transport, {
  String? resource,
  List<String>? authorizationServers,
  List<String>? scopesSupported,
}) {
  final server = Server(
    name: 'prm-auth-fixture',
    version: '1.0.0',
    capabilities: ServerCapabilities.simple(tools: true),
  );
  if (resource != null) {
    server.configureProtectedResource(
      resource: resource,
      authorizationServers: authorizationServers ?? const [],
      scopesSupported: scopesSupported,
    );
  }
  server.connect(transport);
  return server;
}

Future<HttpClientResponse> _post(
  HttpClient httpClient,
  Uri uri, {
  Map<String, String> headers = const {},
}) async {
  final request = await httpClient.postUrl(uri);
  request.headers.set('Content-Type', 'application/json');
  request.headers.set('Accept', 'application/json, text/event-stream');
  headers.forEach(request.headers.set);
  request.write(jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1}));
  return request.close().timeout(const Duration(seconds: 5));
}

void main() {
  group('Server A6/A7 — WWW-Authenticate on 401', () {
    late HttpClient httpClient;

    setUp(() {
      httpClient = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    });

    tearDown(() async {
      httpClient.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test('401 carries resource_metadata challenge when PRM configured',
        () async {
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: 8560,
          authToken: 'server-token',
          isJsonResponseEnabled: true,
        ),
      );
      final server = _attachServer(
        transport,
        resource: 'https://api.example.com',
        authorizationServers: const ['https://as.example.com'],
      );
      try {
        await transport.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final response = await _post(
          httpClient,
          Uri.parse('http://localhost:8560/mcp'),
          headers: {'Authorization': 'Bearer wrong-token'},
        );

        expect(response.statusCode, equals(401));
        final challenge = response.headers.value('www-authenticate');
        expect(challenge, isNotNull);
        expect(challenge, startsWith('Bearer '));
        expect(
          challenge,
          contains(
              'resource_metadata="https://api.example.com/.well-known/oauth-protected-resource"'),
        );
        // Invalid (not missing) token surfaces the OAuth error code.
        expect(challenge, contains('error="invalid_token"'));
        await response.drain<void>();
      } finally {
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });

    test('missing Authorization also gets the challenge (no error code)',
        () async {
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: 8561,
          authToken: 'server-token',
          isJsonResponseEnabled: true,
        ),
      );
      final server = _attachServer(
        transport,
        resource: 'https://api.example.com',
        authorizationServers: const ['https://as.example.com'],
      );
      try {
        await transport.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final response = await _post(
          httpClient,
          Uri.parse('http://localhost:8561/mcp'),
        );

        expect(response.statusCode, equals(401));
        final challenge = response.headers.value('www-authenticate');
        expect(challenge, contains('resource_metadata='));
        await response.drain<void>();
      } finally {
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });

    test('A7 — challengeScope advertises scope= for step-up', () async {
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: 8562,
          authToken: 'server-token',
          isJsonResponseEnabled: true,
          challengeScope: 'mcp:tools mcp:resources',
        ),
      );
      final server = _attachServer(
        transport,
        resource: 'https://api.example.com',
        authorizationServers: const ['https://as.example.com'],
      );
      try {
        await transport.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final response = await _post(
          httpClient,
          Uri.parse('http://localhost:8562/mcp'),
          headers: {'Authorization': 'Bearer wrong-token'},
        );

        expect(response.statusCode, equals(401));
        final challenge = response.headers.value('www-authenticate');
        expect(challenge, contains('scope="mcp:tools mcp:resources"'));
        await response.drain<void>();
      } finally {
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });

    test('A6 opt-in — no PRM configured means no challenge (prior behavior)',
        () async {
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: 8563,
          authToken: 'server-token',
          isJsonResponseEnabled: true,
        ),
      );
      // No configureProtectedResource — PRM absent.
      final server = _attachServer(transport);
      try {
        await transport.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final response = await _post(
          httpClient,
          Uri.parse('http://localhost:8563/mcp'),
          headers: {'Authorization': 'Bearer wrong-token'},
        );

        expect(response.statusCode, equals(401));
        expect(response.headers.value('www-authenticate'), isNull);
        await response.drain<void>();
      } finally {
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });
  });
}
