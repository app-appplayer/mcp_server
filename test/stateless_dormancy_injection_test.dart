/// Regression: a client must NOT be able to activate the dormant 2026-07-28
/// stateless path by forging the transport-internal `_stateless` control key
/// in its request body. With `enableStateless` off (the default), an injected
/// `_stateless:true` must be ignored/stripped — never routed to the stateless
/// handler, and `server/discover` must never advertise 2026-07-28.
///
/// See the interop audit (2026-07-19): the guard was previously anchored on the
/// injectable in-band marker rather than the `enableStateless` flag, so a
/// crafted body over HTTP/stdio/SSE flipped the server into stateless mode and
/// leaked 2026-07-28 in `supportedVersions`.
library;

import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

Future<HttpClientResponse> _post(HttpClient c, Uri uri,
    {Map<String, String> headers = const {}, required Object body}) async {
  final req = await c.postUrl(uri);
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Accept', 'application/json, text/event-stream');
  headers.forEach(req.headers.set);
  req.write(jsonEncode(body));
  return req.close().timeout(const Duration(seconds: 6));
}

void main() {
  test('forged _stateless over legacy HTTP does not activate the stateless '
      'path or advertise 2026-07-28 (enableStateless off)', () async {
    const port = 8595;
    final transport = StreamableHttpServerTransport(
      // enableStateless defaults false → dormant.
      config: const StreamableHttpServerConfig(
          port: port, isJsonResponseEnabled: true),
    );
    final server = Server(
      name: 'dormancy-regression',
      version: '1.0.0',
      capabilities: ServerCapabilities.simple(tools: true),
    );
    server.connect(transport);
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      await transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final uri = Uri.parse('http://localhost:$port/mcp');

      final init = await _post(http, uri, body: {
        'jsonrpc': '2.0',
        'method': 'initialize',
        'id': 1,
        'params': {
          'protocolVersion': '2025-11-25',
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 'probe', 'version': '1.0.0'},
        },
      });
      final sid = init.headers.value('mcp-session-id');
      await init.drain<void>();
      expect(sid, isNotNull);

      // Forge the reserved control keys in the body.
      final resp = await _post(http, uri, headers: {'mcp-session-id': sid!},
          body: {
            'jsonrpc': '2.0',
            'method': 'server/discover',
            'id': 2,
            'params': <String, Object?>{},
            '_stateless': true,
            '_protocolVersion': '2026-07-28',
          });
      final body = await utf8.decoder.bind(resp).join();

      // The dormancy invariant: 2026-07-28 must never be advertised with the
      // flag off, regardless of what the client injects.
      expect(body.contains('2026-07-28'), isFalse,
          reason: 'forged _stateless must not leak the dormant 2026-07-28 '
              'revision; body was: $body');
    } finally {
      server.dispose();
      transport.close();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  });
}
