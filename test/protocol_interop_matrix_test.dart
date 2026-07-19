/// Cross-revision protocol interop matrix.
///
/// The per-version *unit* test (`per_version_compliance_test.dart`) only checks
/// capability-predicate booleans and negotiation-function return values — it
/// brings up no transport, so a server that advertises a revision but does not
/// actually honour its wire behaviour still passes. That blind spot is why
/// 2025-11-25 implementation gaps went undetected until a manual conformance
/// audit.
///
/// This suite closes it for the **server**: for every supported revision it
/// runs a real `initialize` over the real Streamable HTTP wire (raw JSON-RPC,
/// so the negotiated version can be pinned — the in-tree `mcp_client` hardwires
/// its offered version to `latest` and cannot express an older client) and
/// asserts the version-gated behaviours actually engage/disengage for that
/// negotiated revision.
///
/// Gated behaviours asserted per revision:
///   * initialize echoes the negotiated revision (negotiation),
///   * tool-execution-error shape (isError result @2025-11-25 vs protocol error
///     for older — SEP-1303),
///   * JSON-RPC batching accepted only ≤2025-03-26 (removed 2025-06-18).
///
/// Client-side per-revision negotiation is out of scope here because the client
/// only ever offers `latest`; making the client's offered version configurable
/// is a separate (core-API) change.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

/// Every stable revision the server claims to support.
const _revisions = <String>[
  '2024-11-05',
  '2025-03-26',
  '2025-06-18',
  '2025-11-25',
];

Server _bootFixtureServer(StreamableHttpServerTransport transport) {
  final server = Server(
    name: 'interop-matrix-fixture',
    version: '1.0.0',
    capabilities: ServerCapabilities.simple(tools: true),
  );
  server.addTool(
    name: 'boom',
    description: 'A tool that always throws',
    inputSchema: {'type': 'object'},
    handler: (args) async => throw StateError('kaboom'),
  );
  server.addTool(
    name: 'decorated',
    description: 'A tool carrying 2025-11-25 icons + structured output',
    inputSchema: {'type': 'object'},
    outputSchema: {'type': 'object'},
    icons: [
      {'src': 'https://example.com/i.png', 'mimeType': 'image/png'}
    ],
    handler: (args) async =>
        CallToolResult(content: const [TextContent(text: 'ok')]),
  );
  server.connect(transport);
  return server;
}

Future<HttpClientResponse> _post(
  HttpClient httpClient,
  Uri uri, {
  Map<String, String> headers = const {},
  required Object body,
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
        'clientInfo': {'name': 'interop-matrix', 'version': '1.0.0'},
      },
    };

/// Boots a fixture server on [port], initializes it at [version], and hands the
/// live session to [body] as `(uri, sessionId, initResult)`. Tears everything
/// down afterward.
Future<T> _withSession<T>(
  HttpClient httpClient,
  int port,
  String version,
  Future<T> Function(Uri uri, String sessionId, Map<String, dynamic> initResult)
      body,
) async {
  final transport = StreamableHttpServerTransport(
    config: StreamableHttpServerConfig(port: port, isJsonResponseEnabled: true),
  );
  final server = _bootFixtureServer(transport);
  try {
    await transport.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final uri = Uri.parse('http://localhost:$port/mcp');

    final init = await _post(httpClient, uri, body: _initBody(version));
    final sessionId = init.headers.value('mcp-session-id');
    final initText = await utf8.decoder.bind(init).join();
    expect(sessionId, isNotNull,
        reason: 'server must issue a session id on initialize @$version');
    final initJson = jsonDecode(initText) as Map<String, dynamic>;
    final initResult = initJson['result'] as Map<String, dynamic>;

    return await body(uri, sessionId!, initResult);
  } finally {
    server.dispose();
    transport.close();
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

void main() {
  late HttpClient httpClient;

  setUp(() {
    httpClient = HttpClient()..connectionTimeout = const Duration(seconds: 1);
  });
  tearDown(() async {
    httpClient.close(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  // Unique port per (behaviour, revision) so nothing collides.
  var port = 8560;

  group('Negotiation — server echoes every supported revision', () {
    for (final v in _revisions) {
      test('initialize @$v negotiates $v', () async {
        final p = port++;
        await _withSession(httpClient, p, v, (uri, sid, init) async {
          expect(init['protocolVersion'], equals(v),
              reason: 'server must negotiate the exact supported revision');
        });
      });
    }
  });

  group('Tool-execution-error shape is version-gated (SEP-1303)', () {
    for (final v in _revisions) {
      final isLatest = v == '2025-11-25';
      test('@$v → ${isLatest ? 'isError result' : 'protocol error'}', () async {
        final p = port++;
        await _withSession(httpClient, p, v, (uri, sid, _) async {
          final call = await _post(httpClient, uri,
              headers: {'mcp-session-id': sid},
              body: {
                'jsonrpc': '2.0',
                'method': 'tools/call',
                'id': 2,
                'params': {'name': 'boom', 'arguments': <String, Object?>{}},
              });
          final json =
              jsonDecode(await utf8.decoder.bind(call).join()) as Map<String, dynamic>;
          if (isLatest) {
            expect(json.containsKey('error'), isFalse,
                reason: '2025-11-25 self-correction: tool throw is a result');
            expect((json['result'] as Map)['isError'], isTrue);
          } else {
            expect(json.containsKey('error'), isTrue,
                reason: '$v keeps the pre-SEP-1303 protocol-error behaviour');
          }
        });
      });
    }
  });

  group('JSON-RPC batching is version-gated (removed 2025-06-18)', () {
    // Batching was broken over Streamable HTTP until 2026-07-19: the transport
    // hard-cast every body to `Map<String,dynamic>`, so a batch array got a
    // -32700 parse error before the server's batch path ran. Now the transport
    // routes array bodies through `_handleBatchRequest`, version-gated on the
    // session's negotiated revision.
    for (final v in _revisions) {
      final batchingAllowed = v == '2024-11-05' || v == '2025-03-26';
      test('@$v → batch ${batchingAllowed ? 'accepted' : 'rejected'}', () async {
        final p = port++;
        await _withSession(httpClient, p, v, (uri, sid, _) async {
          final resp = await _post(httpClient, uri,
              headers: {'mcp-session-id': sid},
              body: [
                {'jsonrpc': '2.0', 'method': 'ping', 'id': 10},
                {'jsonrpc': '2.0', 'method': 'ping', 'id': 11},
              ]);
          final decoded = jsonDecode(await utf8.decoder.bind(resp).join());
          if (batchingAllowed) {
            expect(decoded, isA<List>(),
                reason: '$v must answer a batch with an array of responses');
            final list = decoded as List;
            expect(list.length, equals(2),
                reason: 'both batched requests must get a response');
            // The two responses correlate to the two request ids.
            final ids = list.map((r) => (r as Map)['id']).toSet();
            expect(ids, equals(<Object?>{10, 11}));
          } else {
            // 2025-06-18+ removed batching: a single JSON-RPC error object
            // (-32600 Invalid Request), never an array or a parse error.
            expect(decoded, isA<Map>(),
                reason: '$v must reject a batch, not process it');
            final error = (decoded as Map)['error'] as Map;
            expect(error['code'], equals(-32600),
                reason: 'batch on $v is a valid array the revision forbids, '
                    'not a -32700 parse error');
          }
        });
      });
    }
  });
}
