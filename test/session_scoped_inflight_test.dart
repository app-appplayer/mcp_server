/// Session-scoped in-flight request tracking (load-bearing).
///
/// JSON-RPC 2.0 guarantees request-id uniqueness only *within* a session, and
/// clients routinely count from 1 per connection. Every in-flight map in
/// `StreamableHttpServerTransport` is therefore keyed by `(session, id)`, never
/// by the bare id — with a bare key the second registration silently overwrites
/// the first, orphaning its `HttpResponse` (that caller hangs with 0 bytes
/// until its own timeout) and delivering the response to the wrong session.
///
/// These tests pin the axis that the rest of the suite does not exercise: two
/// callers holding the SAME request id in flight AT THE SAME TIME. Sequential
/// same-id calls pass even with the defect present, so they prove nothing here
/// — every test below keeps a slow handler occupied so the overlap is real.
///
/// The wire id itself is never rewritten, so `notifications/cancelled` (which
/// references the client's original id) keeps matching; that is pinned too.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

/// Server with a deliberately slow tool, so concurrent calls genuinely overlap
/// in flight (a millisecond-fast handler would finish before the second call
/// arrives and the collision would never form).
Server _buildServer({Duration delay = const Duration(milliseconds: 700)}) {
  final server = Server(
    name: 'inflight-fixture',
    version: '1.0.0',
    capabilities: ServerCapabilities.simple(
      tools: true,
      resources: true,
      resourcesListChanged: true,
    ),
  );
  server.addTool(
    name: 'slow',
    description: 'Echoes after a delay, holding the request in flight',
    inputSchema: {
      'type': 'object',
      'properties': {
        'tag': {'type': 'string'},
      },
      'required': ['tag'],
    },
    handler: (args) async {
      await Future<void>.delayed(delay);
      return CallToolResult(content: [TextContent(text: 'slow:${args['tag']}')]);
    },
  );
  return server;
}

/// One raw HTTP POST. Returns the decoded JSON-RPC message plus the response
/// headers, handling both response modes: a JSON body, or an SSE body whose
/// `data:` frame carries the message.
Future<({Map<String, dynamic> message, HttpHeaders headers, int status})>
    _post(
  int port, {
  required Map<String, dynamic> body,
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 10),
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = await client.postUrl(Uri.parse('http://localhost:$port/mcp'));
    req.headers.set('Content-Type', 'application/json');
    req.headers.set('Accept', 'application/json, text/event-stream');
    headers.forEach(req.headers.set);
    req.write(jsonEncode(body));
    final resp = await req.close().timeout(timeout);
    final raw = await resp.transform(utf8.decoder).join().timeout(timeout);
    return (
      message: _decode(raw),
      headers: resp.headers,
      status: resp.statusCode,
    );
  } finally {
    client.close(force: true);
  }
}

/// POST a notification (no id → 202 Accepted, empty body). Nothing to decode.
Future<void> _postNotification(
  int port, {
  required Map<String, dynamic> body,
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = await client.postUrl(Uri.parse('http://localhost:$port/mcp'));
    req.headers.set('Content-Type', 'application/json');
    req.headers.set('Accept', 'application/json, text/event-stream');
    headers.forEach(req.headers.set);
    req.write(jsonEncode(body));
    final resp = await req.close().timeout(const Duration(seconds: 5));
    await resp.drain<void>();
  } finally {
    client.close(force: true);
  }
}

/// Decode either a plain JSON body or the first SSE `data:` frame.
Map<String, dynamic> _decode(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw StateError('Empty response body — the caller received 0 bytes, '
        'which is exactly what an orphaned in-flight entry produces.');
  }
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    return jsonDecode(trimmed) as Map<String, dynamic>;
  }
  final dataLine = const LineSplitter()
      .convert(trimmed)
      .firstWhere((l) => l.startsWith('data: '), orElse: () => '');
  if (dataLine.isEmpty) throw StateError('No SSE data frame in: $trimmed');
  return jsonDecode(dataLine.substring('data: '.length))
      as Map<String, dynamic>;
}

/// Open a session and return its `Mcp-Session-Id`.
Future<String> _initSession(int port,
    {String version = '2025-11-25'}) async {
  final res = await _post(port, body: {
    'jsonrpc': '2.0',
    'id': 1,
    'method': 'initialize',
    'params': {
      'protocolVersion': version,
      'clientInfo': {'name': 'inflight-probe', 'version': '1.0.0'},
      'capabilities': <String, dynamic>{},
    },
  });
  final sid = res.headers.value('mcp-session-id');
  if (sid == null || sid.isEmpty) {
    throw StateError('No Mcp-Session-Id on initialize: ${res.message}');
  }
  return sid;
}

Map<String, dynamic> _callSlow(dynamic id, String tag) => {
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/call',
      'params': {
        'name': 'slow',
        'arguments': {'tag': tag},
      },
    };

String _textOf(Map<String, dynamic> response) {
  final content = (response['result'] as Map)['content'] as List;
  return (content.first as Map)['text'] as String;
}

void main() {
  group('in-flight requests are keyed by (session, id)', () {
    test(
        'two sessions holding the SAME request id in flight each get their own '
        'response, with their own id, uncrossed', () async {
      const port = 8611;
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(port: port),
      );
      final server = _buildServer();
      server.connect(transport);
      await transport.start();
      addTearDown(transport.close);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final sessionA = await _initSession(port);
      final sessionB = await _initSession(port);
      expect(sessionA, isNot(sessionB));

      // Both use id 2 — the id a client that counts from 1 per connection
      // reaches on its second call. Fired without awaiting so the slow handler
      // holds both in flight simultaneously.
      final a = _post(port,
          body: _callSlow(2, 'A'), headers: {'Mcp-Session-Id': sessionA});
      final b = _post(port,
          body: _callSlow(2, 'B'), headers: {'Mcp-Session-Id': sessionB});

      final results = await Future.wait([a, b]);

      // Neither caller is left hanging on an orphaned stream...
      expect(_textOf(results[0].message), 'slow:A');
      expect(_textOf(results[1].message), 'slow:B');
      // ...and each got its own id back, unrewritten.
      expect(results[0].message['id'], 2);
      expect(results[1].message['id'], 2);
      // Internal routing metadata never reaches the wire.
      expect(results[0].message.containsKey('_targetSessionId'), isFalse);
      expect(results[1].message.containsKey('_targetSessionId'), isFalse);
    });

    test('four sessions on one id all return (none orphaned)', () async {
      const port = 8612;
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(port: port),
      );
      final server = _buildServer();
      server.connect(transport);
      await transport.start();
      addTearDown(transport.close);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final sessions = <String>[];
      for (var i = 0; i < 4; i++) {
        sessions.add(await _initSession(port));
      }

      final calls = <Future<({Map<String, dynamic> message, HttpHeaders headers, int status})>>[
        for (var i = 0; i < 4; i++)
          _post(port,
              body: _callSlow(2, 'S$i'),
              headers: {'Mcp-Session-Id': sessions[i]}),
      ];

      final results = await Future.wait(calls);
      expect(
        results.map((r) => _textOf(r.message)),
        containsAll(<String>['slow:S0', 'slow:S1', 'slow:S2', 'slow:S3']),
      );
    });

    test('sync JSON mode: same id across sessions does not cross completers',
        () async {
      const port = 8613;
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: port,
          isJsonResponseEnabled: true,
        ),
      );
      final server = _buildServer();
      server.connect(transport);
      await transport.start();
      addTearDown(transport.close);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final sessionA = await _initSession(port);
      final sessionB = await _initSession(port);

      final results = await Future.wait([
        _post(port,
            body: _callSlow(2, 'A'), headers: {'Mcp-Session-Id': sessionA}),
        _post(port,
            body: _callSlow(2, 'B'), headers: {'Mcp-Session-Id': sessionB}),
      ]);

      expect(_textOf(results[0].message), 'slow:A');
      expect(_textOf(results[1].message), 'slow:B');
    });

    test(
        'a stateless request in flight does not steal a session request with '
        'the same id', () async {
      const port = 8614;
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: port,
          enableStateless: true,
        ),
      );
      final server = _buildServer();
      server.connect(transport);
      await transport.start();
      addTearDown(transport.close);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final sessionA = await _initSession(port);

      // `send()` checks the stateless completers before the session-scoped SSE
      // routing, so a bare-id stateless entry would swallow the session reply.
      final stateless = _post(
        port,
        body: {
          ..._callSlow(2, 'STATELESS'),
          'params': {
            'name': 'slow',
            'arguments': {'tag': 'STATELESS'},
            '_meta': {
              'protocolVersion': '2026-07-28',
              'clientCapabilities': <String, dynamic>{},
            },
          },
        },
        headers: {'MCP-Protocol-Version': '2026-07-28'},
      );
      final sessioned = _post(port,
          body: _callSlow(2, 'SESSION'),
          headers: {'Mcp-Session-Id': sessionA});

      final results = await Future.wait([stateless, sessioned]);
      expect(_textOf(results[0].message), 'slow:STATELESS');
      expect(_textOf(results[1].message), 'slow:SESSION');
    });

    test('notifications/cancelled still matches the client\'s original id',
        () async {
      const port = 8615;
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(port: port),
      );
      // Long enough that the cancel lands while the handler is still running.
      final server = _buildServer(delay: const Duration(milliseconds: 900));
      server.connect(transport);
      await transport.start();
      addTearDown(transport.close);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final sessionA = await _initSession(port);
      final sessionB = await _initSession(port);

      // Same id in flight on both sessions; only A is cancelled.
      final a = _post(port,
          body: _callSlow(7, 'A'), headers: {'Mcp-Session-Id': sessionA});
      final b = _post(port,
          body: _callSlow(7, 'B'), headers: {'Mcp-Session-Id': sessionB});
      await Future<void>.delayed(const Duration(milliseconds: 150));

      await _postNotification(port, body: {
        'jsonrpc': '2.0',
        'method': 'notifications/cancelled',
        'params': {'requestId': 7, 'reason': 'test'},
      }, headers: {
        'Mcp-Session-Id': sessionA
      });

      final resA = await a;
      final resB = await b;

      // A: cancelled — proof the cancel found the operation by the id the
      // client actually sent (the wire id is never rewritten).
      expect(resA.message['error'], isNotNull);
      expect((resA.message['error'] as Map)['code'],
          ErrorCode.operationCancelled);
      // B: untouched, same id, different session.
      expect(_textOf(resB.message), 'slow:B');
    });
  });
}
