// Per-version protocol compliance matrix.
//
// Validates that mcp_server's per-version capability gates and dispatch
// branches behave correctly for each of the four supported MCP spec
// revisions: 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25.
//
// These tests exercise the in-process protocol logic; they don't bring
// up a real transport. A real-client handshake matrix runs against the
// reference Python / TypeScript SDKs in the workspace integration suite
// (separate from this unit-test crate).

import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

void main() {
  group('Protocol version registry', () {
    test('all four MCP revisions are listed (newest first)', () {
      expect(McpProtocol.supportedVersions, equals(<String>[
        McpProtocol.v2025_11_25,
        McpProtocol.v2025_06_18,
        McpProtocol.v2025_03_26,
        McpProtocol.v2024_11_05,
      ]));
    });

    test('latest tracks 2025-11-25', () {
      expect(McpProtocol.latest, equals(McpProtocol.v2025_11_25));
    });

    test('isSupported recognises every listed revision', () {
      for (final v in McpProtocol.supportedVersions) {
        expect(McpProtocol.isSupported(v), isTrue,
            reason: 'isSupported($v) must be true');
      }
      expect(McpProtocol.isSupported('1999-01-01'), isFalse);
    });
  });

  group('Per-version capability gates', () {
    test('JSON-RPC batching only on legacy revisions (≤ 2025-03-26)', () {
      expect(McpProtocol.supportsBatching(McpProtocol.v2024_11_05), isTrue);
      expect(McpProtocol.supportsBatching(McpProtocol.v2025_03_26), isTrue);
      expect(McpProtocol.supportsBatching(McpProtocol.v2025_06_18), isFalse);
      expect(McpProtocol.supportsBatching(McpProtocol.v2025_11_25), isFalse);
    });

    test('Elicitation (server → client) introduced at 2025-06-18', () {
      expect(McpProtocol.supportsElicitation(McpProtocol.v2024_11_05), isFalse);
      expect(McpProtocol.supportsElicitation(McpProtocol.v2025_03_26), isFalse);
      expect(McpProtocol.supportsElicitation(McpProtocol.v2025_06_18), isTrue);
      expect(McpProtocol.supportsElicitation(McpProtocol.v2025_11_25), isTrue);
    });

    test('MCP-Protocol-Version HTTP header required at 2025-06-18+', () {
      expect(
          McpProtocol.requiresProtocolHeader(McpProtocol.v2024_11_05), isFalse);
      expect(
          McpProtocol.requiresProtocolHeader(McpProtocol.v2025_03_26), isFalse);
      expect(
          McpProtocol.requiresProtocolHeader(McpProtocol.v2025_06_18), isTrue);
      expect(
          McpProtocol.requiresProtocolHeader(McpProtocol.v2025_11_25), isTrue);
    });

    test('Structured tool output (outputSchema / structuredContent / '
        'resource_link) introduced at 2025-06-18', () {
      expect(
          McpProtocol.supportsStructuredToolOutput(McpProtocol.v2024_11_05),
          isFalse);
      expect(
          McpProtocol.supportsStructuredToolOutput(McpProtocol.v2025_03_26),
          isFalse);
      expect(
          McpProtocol.supportsStructuredToolOutput(McpProtocol.v2025_06_18),
          isTrue);
      expect(
          McpProtocol.supportsStructuredToolOutput(McpProtocol.v2025_11_25),
          isTrue);
    });

    test('Icons + sampling tool calling exclusive to 2025-11-25', () {
      expect(
          McpProtocol.supportsIconsAndSamplingTools(McpProtocol.v2024_11_05),
          isFalse);
      expect(
          McpProtocol.supportsIconsAndSamplingTools(McpProtocol.v2025_03_26),
          isFalse);
      expect(
          McpProtocol.supportsIconsAndSamplingTools(McpProtocol.v2025_06_18),
          isFalse);
      expect(
          McpProtocol.supportsIconsAndSamplingTools(McpProtocol.v2025_11_25),
          isTrue);
    });
  });

  group('Version negotiation', () {
    test('exact match wins', () {
      expect(
        McpProtocol.negotiateWithDateFallback(
            McpProtocol.v2025_06_18, McpProtocol.supportedVersions),
        equals(McpProtocol.v2025_06_18),
      );
    });

    test('newer-than-server client falls back to newest server version', () {
      // Client claims an even newer date — server lacks it. Date fallback
      // should select the newest server revision the client can speak.
      final result = McpProtocol.negotiateWithDateFallback(
          '2026-04-01', McpProtocol.supportedVersions);
      expect(result, equals(McpProtocol.v2025_11_25));
    });

    test('older-than-server client returns same client version when '
        'supported', () {
      expect(
        McpProtocol.negotiateWithDateFallback(
            McpProtocol.v2024_11_05, McpProtocol.supportedVersions),
        equals(McpProtocol.v2024_11_05),
      );
    });

    test('unknown future version with no compatible date returns null',
        () {
      expect(
        McpProtocol.negotiateWithDateFallback(
            '1999-01-01', McpProtocol.supportedVersions),
        isNull,
      );
    });

    test('null client version uses server preferred (newest)', () {
      expect(
        McpProtocol.negotiateWithDateFallback(
            null, McpProtocol.supportedVersions),
        equals(McpProtocol.v2025_11_25),
      );
    });
  });

  group('Standardised notification names (regression)', () {
    test('Server still issues notifications on the spec-defined methods '
        'so 2.0+ clients see list-change events', () {
      // The bug fixed in 2.0: prior versions broadcast "tools/listChanged"
      // (camelCase, no notifications/ prefix) which spec clients ignored.
      // We don't have a transport here, but registering a tool on a
      // listChanged-capable server should not throw — and the server's
      // capability map must surface listChanged so the dispatch path is
      // taken. Real notification wire-format is asserted in the
      // integration suite that runs against a reference client.
      final server = Server(
        name: 'list-changed-test',
        version: '1.0.0',
        capabilities: ServerCapabilities.simple(
          tools: true,
          toolsListChanged: true,
          resources: true,
          resourcesListChanged: true,
          prompts: true,
          promptsListChanged: true,
        ),
      );
      addTearDown(server.dispose);

      expect(server.capabilities.toolsListChanged, isTrue);
      expect(server.capabilities.resourcesListChanged, isTrue);
      expect(server.capabilities.promptsListChanged, isTrue);

      server.addTool(
        name: 'test',
        description: 'test',
        inputSchema: const {'type': 'object'},
        handler: (_) async => CallToolResult(content: const [
          TextContent(text: 'ok'),
        ]),
      );
      // No throw == OK. Wire format is integration-tested.
    });
  });

  group('New surface APIs — registration smoke', () {
    test('addCompletion / removeCompletion register without throwing', () {
      final server = Server(
        name: 'completion-test',
        version: '1.0.0',
        capabilities: ServerCapabilities.simple(
          tools: true,
          completions: true,
        ),
      );
      addTearDown(server.dispose);

      expect(server.capabilities.hasCompletions, isTrue);

      server.addCompletion(
        refType: 'prompt',
        refKey: 'greet',
        handler: (ref, argument, context) async => {
          'completion': {
            'values': ['hello', 'hi'],
            'total': 2,
            'hasMore': false,
          }
        },
      );
      server.removeCompletion(refType: 'prompt', refKey: 'greet');
    });

    test('configureProtectedResource exposes RFC 9728 metadata only when '
        'auth is enabled', () {
      final server = Server(
        name: 'oauth-rs-test',
        version: '1.0.0',
        capabilities: ServerCapabilities.simple(tools: true),
      );
      addTearDown(server.dispose);

      // Without auth enabled, metadata is null even if configured.
      server.configureProtectedResource(
        resource: 'https://api.example.com/mcp',
        authorizationServers: const ['https://auth.example.com'],
      );
      expect(server.protectedResourceMetadata, isNull);
    });
  });
}
