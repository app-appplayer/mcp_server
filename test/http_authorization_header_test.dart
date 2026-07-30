/// A bearer token sent the way the specification says — an `Authorization`
/// header — must reach the validator installed by `enableAuthentication`.
///
/// It previously did not: the token was looked for in the JSON-RPC body and on
/// the session, neither of which the Streamable HTTP transport populates from
/// the header, so a standard client's request was rejected as carrying no
/// token and the validator was never called. Putting the token in `params`
/// worked, but no standard client does that.
///
/// These run over a real socket — the defect lives in the transport→server
/// hand-off, which a mock transport does not exercise.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_server/mcp_server.dart';
import 'package:test/test.dart';

const _protocolVersion = '2025-11-25';

Map<String, Map<String, dynamic>> _keys() => {
      'alice-token': {
        'sub': 'alice',
        'scopes': ['tools:execute', 'resources:read'],
      },
    };

/// Server whose `whoami` tool records the caller it observed.
({Server server, List<AuthContext?> seen}) _buildServer() {
  final seen = <AuthContext?>[];
  final server = Server(
    name: 'header-auth-fixture',
    version: '1.0.0',
    capabilities: ServerCapabilities.simple(tools: true),
  );
  server.addTool(
    name: 'whoami',
    description: 'Records the caller the handler observed',
    inputSchema: const {'type': 'object', 'additionalProperties': true},
    handler: (args) async {
      final caller = McpCaller.current;
      seen.add(caller);
      return CallToolResult(
        content: [TextContent(text: caller?.userId ?? 'anonymous')],
      );
    },
  );
  server.enableAuthentication(ApiKeyValidator(_keys()));
  return (server: server, seen: seen);
}

Future<({Map<String, dynamic> message, String? sessionId})> _post(
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
    final resp = await req.close().timeout(const Duration(seconds: 10));
    final raw =
        await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
    final sid = resp.headers.value('mcp-session-id');
    for (final line in const LineSplitter().convert(raw)) {
      if (line.startsWith('data: ')) {
        return (
          message: jsonDecode(line.substring(6)) as Map<String, dynamic>,
          sessionId: sid,
        );
      }
    }
    return (message: jsonDecode(raw) as Map<String, dynamic>, sessionId: sid);
  } finally {
    client.close(force: true);
  }
}

/// Initialize and return the negotiated session id, which every following
/// request must carry.
Future<String?> _initialize(int port,
    {Map<String, String> headers = const {}}) async {
  final r = await _post(port, headers: headers, body: {
    'jsonrpc': '2.0',
    'id': 0,
    'method': 'initialize',
    'params': {
      'protocolVersion': _protocolVersion,
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'header-auth-test', 'version': '1.0.0'},
    },
  });
  return r.sessionId;
}

Map<String, dynamic> _callWhoami(int id) => {
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/call',
      'params': {'name': 'whoami', 'arguments': <String, Object?>{}},
    };

void main() {
  group('Authorization header reaches the validator', () {
    late Server server;
    late List<AuthContext?> seen;
    late StreamableHttpServerTransport transport;
    late int port;

    setUp(() async {
      final f = _buildServer();
      server = f.server;
      seen = f.seen;
      port = 8730 + (DateTime.now().microsecond % 200);
      transport = StreamableHttpServerTransport(
        config: StreamableHttpServerConfig(
          port: port,
          isJsonResponseEnabled: true,
        ),
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

    test('a Bearer header authenticates the call', () async {
      const auth = {'Authorization': 'Bearer alice-token'};
      final sid = await _initialize(port, headers: auth);

      final res = await _post(port,
          headers: {...auth, if (sid != null) 'mcp-session-id': sid},
          body: _callWhoami(1));

      expect(res.message['error'], isNull,
          reason: 'header-authenticated call was rejected: '
              '${res.message['error']}');
      expect(seen, hasLength(1));
      expect(seen.single?.userId, 'alice');
    });

    test('the scheme is matched case-insensitively', () async {
      const auth = {'Authorization': 'bearer alice-token'};
      final sid = await _initialize(port, headers: auth);

      final res = await _post(port,
          headers: {...auth, if (sid != null) 'mcp-session-id': sid},
          body: _callWhoami(1));

      expect(res.message['error'], isNull);
      expect(seen.single?.userId, 'alice');
    });

    test('an unknown token is refused and never runs the handler', () async {
      const auth = {'Authorization': 'Bearer not-a-key'};
      final sid = await _initialize(port, headers: auth);

      final res = await _post(port,
          headers: {...auth, if (sid != null) 'mcp-session-id': sid},
          body: _callWhoami(1));

      expect(res.message['error'], isNotNull);
      expect(seen, isEmpty);
    });

    test('no header is refused as unauthenticated', () async {
      final sid = await _initialize(port);

      final res = await _post(port,
          headers: {if (sid != null) 'mcp-session-id': sid},
          body: _callWhoami(1));

      expect(res.message['error'], isNotNull);
      expect(seen, isEmpty);
    });

    test('a body-supplied _authorization cannot forge a caller', () async {
      // `_authorization` is a reserved transport key. A client that puts one in
      // its request body must not be able to authenticate with it — otherwise
      // the header check is decorative.
      final sid = await _initialize(port);

      final res = await _post(port,
          headers: {if (sid != null) 'mcp-session-id': sid},
          body: {
            ..._callWhoami(1),
            '_authorization': 'alice-token',
          });

      expect(res.message['error'], isNotNull,
          reason: 'a forged _authorization key authenticated the request');
      expect(seen, isEmpty);
    });
  });
}
