/// 2026-07-28 stateless core (SEP-2577) — COEXISTENCE (load-bearing).
///
/// One running `mcp_server` with `enableStateless: true` must answer BOTH
///  (a) a legacy 2025-11-25 handshake client, AND
///  (b) a 2026-07-28 stateless client,
/// correctly and concurrently, with no session leakage between them. Plus the
/// version gate (flag OFF rejects 2026-07-28), the `server/discover` shape
/// (shared `describe()` parity), and the HTTP `_meta`/header-mismatch rule.
///
/// Uses the real Streamable HTTP wire (raw `HttpClient` for the stateless /
/// gate assertions) and the in-tree `mcp_client` (via pubspec_overrides) for
/// the handshake + stateless client interop.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';
import 'package:mcp_client/mcp_client.dart' as mc;

Server _buildServer({String name = 'coexist-fixture'}) {
  final server = Server(
    name: name,
    version: '1.0.0',
    instructions: 'Use echo to repeat text.',
    capabilities: ServerCapabilities.simple(tools: true),
  );
  server.addTool(
    name: 'echo',
    description: 'Echo the input text',
    inputSchema: {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
      },
      'required': ['text'],
    },
    handler: (args) async => CallToolResult(
      content: [TextContent(text: 'echo:${args['text']}')],
    ),
  );
  return server;
}

Future<Map<String, dynamic>> _rawPost(
  int port, {
  required Map<String, dynamic> body,
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final req = await client.postUrl(Uri.parse('http://localhost:$port/mcp'));
    req.headers.set('Content-Type', 'application/json');
    req.headers.set('Accept', 'application/json, text/event-stream');
    // 2026-07-28 mirrors the method (and target name where the operation has
    // one) into headers; a conformant client always sends them.
    final method = body['method'];
    if (body['id'] != null && method is String) {
      req.headers.set('Mcp-Method', method);
      const namedMethods = {'tools/call', 'resources/read', 'prompts/get'};
      if (namedMethods.contains(method)) {
        final params = body['params'];
        final target = params is Map ? (params['name'] ?? params['uri']) : null;
        if (target != null) req.headers.set('Mcp-Name', '$target');
      }
    }
    headers.forEach(req.headers.set);
    req.write(jsonEncode(body));
    final resp = await req.close().timeout(const Duration(seconds: 5));
    final text = await utf8.decoder.bind(resp).join();
    return {
      'status': resp.statusCode,
      'sessionId': resp.headers.value('mcp-session-id'),
      'protocolVersion': resp.headers.value('mcp-protocol-version'),
      'body': text.isEmpty ? null : jsonDecode(text),
    };
  } finally {
    client.close(force: true);
  }
}

void main() {
  group('2026-07-28 stateless coexistence', () {
    test(
        'one enableStateless server answers a handshake client AND a stateless client',
        () async {
      const port = 8571;
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: port,
          isJsonResponseEnabled: true,
          enableStateless: true,
        ),
      );
      final server = _buildServer();
      server.connect(transport);
      await transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      try {
        // --- (a) Legacy 2025-11-25 handshake client ---
        final legacyTx = await mc.StreamableHttpClientTransport.create(
          baseUrl: 'http://localhost:$port/mcp',
        );
        final legacy = mc.Client(name: 'legacy', version: '1.0.0');
        await legacy.connect(legacyTx);
        expect(legacy.negotiatedProtocolVersion, mc.McpProtocol.v2025_11_25);
        final legacyTools = await legacy.listTools();
        expect(legacyTools.map((t) => t.name), contains('echo'));
        final legacyCall = await legacy.callTool('echo', {'text': 'hi'});
        expect((legacyCall.content.first as mc.TextContent).text, 'echo:hi');

        // --- (b) 2026-07-28 stateless client (same server) ---
        final statelessTx = await mc.StreamableHttpClientTransport.create(
          baseUrl: 'http://localhost:$port/mcp',
        );
        final stateless = mc.Client(name: 'stateless', version: '2.0.0');
        await stateless.connect(statelessTx, statelessMode: true);
        expect(stateless.isStateless, isTrue);

        // discover() → shared describe() capabilities + supportedVersions.
        final discovered = await stateless.discover();
        expect(discovered.supportedVersions, contains('2026-07-28'));
        expect(discovered.supportedVersions, contains('2025-11-25'));
        expect(discovered.capabilities.tools, isNotNull);
        expect(discovered.instructions, 'Use echo to repeat text.');

        final statelessTools = await stateless.listTools();
        expect(statelessTools.map((t) => t.name), contains('echo'));
        final statelessCall =
            await stateless.callTool('echo', {'text': 'yo'});
        expect(
            (statelessCall.content.first as mc.TextContent).text, 'echo:yo');

        // --- Concurrency + no leakage: interleave both after warm-up ---
        final results = await Future.wait([
          legacy.callTool('echo', {'text': 'L'}),
          stateless.callTool('echo', {'text': 'S'}),
        ]);
        expect((results[0].content.first as mc.TextContent).text, 'echo:L');
        expect((results[1].content.first as mc.TextContent).text, 'echo:S');

        legacy.disconnect();
        stateless.disconnect();
      } finally {
        transport.close();
      }
    });

    test('stateless works on an SSE-mode server (no JSON response mode)',
        () async {
      // Proves the stateless response path is independent of the JSON/SSE
      // response-mode config.
      const port = 8572;
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: port,
          isJsonResponseEnabled: false, // default SSE mode
          enableStateless: true,
        ),
      );
      final server = _buildServer();
      server.connect(transport);
      await transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      try {
        final resp = await _rawPost(
          port,
          headers: const {'MCP-Protocol-Version': '2026-07-28'},
          body: {
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'server/discover',
            'params': {
              '_meta': {
                'io.modelcontextprotocol/protocolVersion': '2026-07-28',
                'io.modelcontextprotocol/clientCapabilities': <String, dynamic>{},
              },
            },
          },
        );
        expect(resp['status'], 200);
        // Stateless response MUST NOT carry a session id; echoes version.
        expect(resp['sessionId'], isNull);
        expect(resp['protocolVersion'], '2026-07-28');
        final result = (resp['body'] as Map)['result'] as Map;
        expect(result['supportedVersions'], contains('2026-07-28'));
      } finally {
        transport.close();
      }
    });

    test('version gate: flag OFF rejects 2026-07-28 with -32022 (HTTP 400)',
        () async {
      const port = 8573;
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: port,
          isJsonResponseEnabled: true,
          // enableStateless defaults to false — dormant.
        ),
      );
      final server = _buildServer();
      server.connect(transport);
      await transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      try {
        final resp = await _rawPost(
          port,
          headers: const {'MCP-Protocol-Version': '2026-07-28'},
          body: {
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'server/discover',
            'params': {
              '_meta': {
                'io.modelcontextprotocol/protocolVersion': '2026-07-28',
                'io.modelcontextprotocol/clientCapabilities': <String, dynamic>{},
              },
            },
          },
        );
        expect(resp['status'], 400);
        final error = (resp['body'] as Map)['error'] as Map;
        expect(error['code'], -32022);
        expect((error['data'] as Map)['requested'], '2026-07-28');
        expect((error['data'] as Map)['supported'], isA<List>());
      } finally {
        transport.close();
      }
    });

    test('header mismatch: _meta.protocolVersion != header → -32020 (HTTP 400)',
        () async {
      const port = 8574;
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: port,
          isJsonResponseEnabled: true,
          enableStateless: true,
        ),
      );
      final server = _buildServer();
      server.connect(transport);
      await transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      try {
        final resp = await _rawPost(
          port,
          headers: const {'MCP-Protocol-Version': '2026-07-28'},
          body: {
            'jsonrpc': '2.0',
            'id': 9,
            'method': 'server/discover',
            'params': {
              '_meta': {
                // Deliberately disagrees with the header.
                'io.modelcontextprotocol/protocolVersion': '2025-11-25',
                'io.modelcontextprotocol/clientCapabilities': <String, dynamic>{},
              },
            },
          },
        );
        expect(resp['status'], 400);
        expect(((resp['body'] as Map)['error'] as Map)['code'], -32020);
      } finally {
        transport.close();
      }
    });

    test('describe() parity: initialize result caps == server/discover caps',
        () async {
      const port = 8575;
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: port,
          isJsonResponseEnabled: true,
          enableStateless: true,
        ),
      );
      final server = _buildServer();
      server.connect(transport);
      await transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      try {
        // Handshake initialize (legacy path).
        final initResp = await _rawPost(
          port,
          body: {
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'initialize',
            'params': {
              'protocolVersion': '2025-11-25',
              'clientInfo': {'name': 'x', 'version': '1'},
              'capabilities': <String, dynamic>{},
            },
          },
        );
        final initCaps =
            ((initResp['body'] as Map)['result'] as Map)['capabilities'];

        // server/discover (stateless path).
        final discResp = await _rawPost(
          port,
          headers: const {'MCP-Protocol-Version': '2026-07-28'},
          body: {
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'server/discover',
            'params': {
              '_meta': {
                'io.modelcontextprotocol/protocolVersion': '2026-07-28',
                'io.modelcontextprotocol/clientCapabilities': <String, dynamic>{},
              },
            },
          },
        );
        final discResult = (discResp['body'] as Map)['result'] as Map;
        final discCaps = discResult['capabilities'];

        // The shared describe() must produce the SAME capability object.
        expect(discCaps, equals(initCaps));
        // Result _meta carries serverInfo (ResultMetaObject).
        final meta = discResult['_meta'] as Map;
        expect(meta['io.modelcontextprotocol/serverInfo'],
            {'name': 'coexist-fixture', 'version': '1.0.0'});
      } finally {
        transport.close();
      }
    });
  });
}
