/// The CORS allow-list must cover every header a conformant client sends.
///
/// This has now been wrong three times — `MCP-Protocol-Version` (2.1.2),
/// then `Cache-Control` / `Mcp-Method` / `Mcp-Name` / `X-Heartbeat-Interval`.
/// Each omission has the same shape: a browser refuses to issue a request
/// carrying a header the server has not allowed, so the call dies in preflight
/// with nothing in the server log, and it is invisible to every non-browser
/// client — including our own test suite, unless the invariant is pinned.
///
/// So pin the invariant rather than the string: a preflight must allow each
/// header the specification and our client actually put on the wire.
@TestOn('vm')
library;

import 'dart:io';

import 'package:mcp_server/mcp_server.dart';
import 'package:test/test.dart';

/// Headers `mcp_client` sends, by transport.
///
/// Browser-forbidden header names (`Accept-Encoding`, `Connection`) are
/// excluded — the browser sets those itself and they never appear in a
/// preflight request-headers list.
const _clientHeaders = <String>[
  'Content-Type',
  'Authorization',
  'Accept',
  'mcp-session-id',
  'last-event-id',
  'MCP-Protocol-Version', // 2025-11-25 on
  'Cache-Control', // SSE stream: no-cache
  'Mcp-Method', // required on 2026-07-28
  'Mcp-Name', // required on 2026-07-28 for named methods
  'X-Heartbeat-Interval', // compressed SSE transport
];

void main() {
  group('CorsConfig defaults', () {
    test('allow every header a conformant client sends', () {
      const cors = CorsConfig();
      final allowed = cors.allowHeaders
          .split(',')
          .map((h) => h.trim().toLowerCase())
          .toSet();

      final missing = _clientHeaders
          .where((h) => !allowed.contains(h.toLowerCase()))
          .toList();

      expect(
        missing,
        isEmpty,
        reason: 'a browser cannot send these, so the request dies in preflight '
            'before reaching the server: $missing',
      );
    });

    test('expose the response headers a client must read back', () {
      const cors = CorsConfig();
      final exposed = cors.exposeHeaders
          .split(',')
          .map((h) => h.trim().toLowerCase())
          .toSet();

      // A browser hides every non-simple response header. Without these the
      // client cannot read the session it just negotiated, nor the challenge
      // telling it how to authenticate.
      expect(exposed, contains('mcp-session-id'));
      expect(exposed, contains('mcp-protocol-version'));
      expect(exposed, contains('www-authenticate'));
    });
  });

  group('preflight over a live socket', () {
    late StreamableHttpServerTransport transport;
    late Server server;
    late int port;

    setUp(() async {
      port = 8690 + (DateTime.now().microsecond % 150);
      transport = StreamableHttpServerTransport(
        config: StreamableHttpServerConfig(
          port: port,
          isJsonResponseEnabled: true,
        ),
      );
      server = Server(
        name: 'cors-fixture',
        version: '1.0.0',
        capabilities: ServerCapabilities.simple(tools: true),
      );
      server.connect(transport);
      await transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });

    tearDown(() async {
      server.dispose();
      transport.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    test('OPTIONS answers with every client header allowed', () async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      try {
        final req = await client.openUrl(
          'OPTIONS',
          Uri.parse('http://localhost:$port/mcp'),
        );
        req.headers.set('Origin', 'http://localhost:1234');
        req.headers.set('Access-Control-Request-Method', 'POST');
        req.headers
            .set('Access-Control-Request-Headers', _clientHeaders.join(', '));
        final resp = await req.close().timeout(const Duration(seconds: 10));
        await resp.drain<void>();

        final allowRaw = resp.headers.value('access-control-allow-headers');
        expect(allowRaw, isNotNull,
            reason: 'preflight carried no Access-Control-Allow-Headers');
        final allowed =
            allowRaw!.split(',').map((h) => h.trim().toLowerCase()).toSet();

        final missing = _clientHeaders
            .where((h) => !allowed.contains(h.toLowerCase()))
            .toList();
        expect(missing, isEmpty,
            reason: 'browser would refuse to send: $missing');
      } finally {
        client.close(force: true);
      }
    });
  });
}
