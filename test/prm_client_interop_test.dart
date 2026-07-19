/// MCP 2025-11-25 auth stack — server<->client INTEROP.
///
/// The single wire-contract test proving the server's emitted challenge and
/// the client's parser agree: boot a real `mcp_server` with OAuth Protected
/// Resource metadata configured, hit it unauthenticated over the real
/// Streamable HTTP transport, and feed the actual `WWW-Authenticate` response
/// header into the actual `mcp_client` parser — asserting the client reaches
/// the RFC 9728 PRM URL (and reads the SEP-835 step-up scope).
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';
// The in-tree client (resolved via pubspec_overrides path).
import 'package:mcp_client/mcp_client.dart' as client;

void main() {
  test(
      'server 401 WWW-Authenticate is parsed by the client to the PRM URL + scope',
      () async {
    const port = 8530;
    const resource = 'https://api.example.com';

    final transport = StreamableHttpServerTransport(
      config: const StreamableHttpServerConfig(
        port: port,
        authToken: 'server-token',
        isJsonResponseEnabled: true,
        challengeScope: 'mcp:tools mcp:resources',
      ),
    );
    final server = Server(
      name: 'interop-fixture',
      version: '1.0.0',
      capabilities: ServerCapabilities.simple(tools: true),
    );
    server.configureProtectedResource(
      resource: resource,
      authorizationServers: const ['https://as.example.com'],
      scopesSupported: const ['mcp:tools', 'mcp:resources'],
    );
    server.connect(transport);

    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 1);

    try {
      await transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // --- Real server wire: unauthenticated POST -> 401 + challenge. ---
      final request =
          await httpClient.postUrl(Uri.parse('http://localhost:$port/mcp'));
      request.headers.set('Content-Type', 'application/json');
      request.headers.set('Accept', 'application/json, text/event-stream');
      request.write(
          jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1}));
      final response =
          await request.close().timeout(const Duration(seconds: 5));

      expect(response.statusCode, equals(401));
      final rawChallenge = response.headers.value('www-authenticate');
      expect(rawChallenge, isNotNull);
      await response.drain<void>();

      // --- Real client parse: drive the client's parser on the server's
      // actual header and assert it reaches the PRM URL + step-up scope. ---
      final challenge = client.WwwAuthenticateChallenge.parse(rawChallenge);
      expect(challenge, isNotNull);
      expect(challenge!.isBearer, isTrue);
      expect(
        challenge.resourceMetadata,
        equals('$resource/.well-known/oauth-protected-resource'),
      );
      expect(challenge.scopes, equals(['mcp:tools', 'mcp:resources']));

      // The client's well-known fallback derives the same PRM URL from the
      // resource origin (SEP-985 fallback), matching the header-supplied one.
      final oauthClient = client.HttpOAuthClient(
        config: const client.OAuthConfig(
          authorizationEndpoint: 'https://as.example.com/authorize',
          tokenEndpoint: 'https://as.example.com/token',
          clientId: 'interop-client',
        ),
      );
      final fallbackUrl =
          oauthClient.wellKnownProtectedResourceUrl('$resource/mcp');
      expect(fallbackUrl.toString(),
          equals(challenge.resourceMetadata));
      oauthClient.close();
    } finally {
      server.dispose();
      transport.close();
      httpClient.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  });
}
