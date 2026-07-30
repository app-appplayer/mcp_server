/// Request-scoped caller (`McpCaller.current`).
///
/// Handler signatures carry no request context, so the authenticated caller is
/// published on the zone for the duration of one request — the same mechanism
/// the in-flight operation already uses. These tests pin the properties that
/// make it usable as an authorization input rather than a hint:
///
///   - tool AND resource handlers see it (a per-handler wrap would leave
///     whichever surface it missed as a way around the check),
///   - an anonymous request is `null`, never a stale or empty caller,
///   - concurrent requests do not observe each other's caller,
///   - nothing leaks outside the request.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:mcp_server/mcp_server.dart';
import 'package:test/test.dart';

class _MockTransport implements ServerTransport {
  final _in = StreamController<dynamic>.broadcast();
  final _close = Completer<void>();
  final List<dynamic> sent = [];
  bool _closed = false;

  @override
  Stream<dynamic> get onMessage => _in.stream;

  @override
  Future<void> get onClose => _close.future;

  @override
  void send(dynamic message) {
    if (!_closed) sent.add(message);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    if (!_close.isCompleted) _close.complete();
    if (!_in.isClosed) _in.close();
  }

  void receive(dynamic message) {
    if (!_closed && !_in.isClosed) _in.add(message);
  }
}

const _protocolVersion = '2025-11-25';

/// Key info the validator hands back verbatim as `AuthContext.userInfo`.
Map<String, Map<String, dynamic>> _keys() => {
      'alice-token': {
        'sub': 'alice',
        'scopes': ['tools:execute', 'resources:read'],
      },
      'bob-token': {
        'sub': 'bob',
        'scopes': ['tools:execute', 'resources:read'],
      },
    };

/// Boots a server whose tool and resource handlers both record the caller they
/// saw. [authenticated] false leaves the middleware off — the anonymous shape.
({
  Server server,
  _MockTransport transport,
  List<AuthContext?> seen,
}) _boot({bool authenticated = true, Duration toolDelay = Duration.zero}) {
  final seen = <AuthContext?>[];
  final server = Server(
    name: 'caller-fixture',
    version: '1.0.0',
    capabilities: ServerCapabilities.simple(tools: true, resources: true),
  );

  server.addTool(
    name: 'whoami',
    description: 'Records the caller the handler observed',
    inputSchema: const {'type': 'object', 'additionalProperties': true},
    handler: (args) async {
      // Delay across an await so the zone must survive the async hop, not just
      // the synchronous portion of the handler.
      if (toolDelay > Duration.zero) await Future<void>.delayed(toolDelay);
      final caller = McpCaller.current;
      seen.add(caller);
      return CallToolResult(
        content: [TextContent(text: caller?.userId ?? 'anonymous')],
      );
    },
  );

  server.addResource(
    uri: 'test://whoami',
    name: 'whoami',
    description: 'Records the caller the resource handler observed',
    mimeType: 'text/plain',
    handler: (uri, params) async {
      final caller = McpCaller.current;
      seen.add(caller);
      return ReadResourceResult(contents: [
        ResourceContentInfo(uri: uri, text: caller?.userId ?? 'anonymous'),
      ]);
    },
  );

  if (authenticated) {
    server.enableAuthentication(ApiKeyValidator(_keys()));
  }

  final transport = _MockTransport();
  server.connect(transport);
  return (server: server, transport: transport, seen: seen);
}

Future<void> _initialize(_MockTransport transport) async {
  transport.receive({
    'jsonrpc': '2.0',
    'id': 0,
    'method': 'initialize',
    'params': {
      'protocolVersion': _protocolVersion,
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'caller-test', 'version': '1.0.0'},
    },
  });
  await _settle();
}

/// Let the server's async dispatch finish. The mock transport is synchronous on
/// send, so a few microtask drains are enough.
Future<void> _settle([int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, dynamic> _callTool(int id, {String? token}) => {
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/call',
      'params': {
        'name': 'whoami',
        'arguments': <String, Object?>{},
        if (token != null) 'authorization': token,
      },
    };

Map<String, dynamic> _readResource(int id, {String? token}) => {
      'jsonrpc': '2.0',
      'id': id,
      'method': 'resources/read',
      'params': {
        'uri': 'test://whoami',
        if (token != null) 'authorization': token,
      },
    };

/// The text payload of a `tools/call` / `resources/read` response by id.
String? _textFor(List<dynamic> sent, int id) {
  for (final raw in sent) {
    final msg = raw is String
        ? jsonDecode(raw) as Map<String, dynamic>
        : Map<String, dynamic>.from(raw as Map);
    if (msg['id'] != id) continue;
    final result = msg['result'];
    if (result is! Map) continue;
    final content = result['content'] ?? result['contents'];
    if (content is List && content.isNotEmpty) {
      final first = Map<String, dynamic>.from(content.first as Map);
      return first['text'] as String?;
    }
  }
  return null;
}

void main() {
  group('McpCaller.current', () {
    test('a tool handler sees the authenticated caller', () async {
      final f = _boot();
      addTearDown(f.server.dispose);
      await _initialize(f.transport);

      f.transport.receive(_callTool(1, token: 'alice-token'));
      await _settle();

      expect(f.seen, hasLength(1));
      expect(f.seen.single, isNotNull);
      expect(f.seen.single!.userId, 'alice');
      expect(f.seen.single!.hasScope('tools:execute'), isTrue);
      expect(_textFor(f.transport.sent, 1), 'alice');
    });

    test('a resource handler sees the same caller', () async {
      final f = _boot();
      addTearDown(f.server.dispose);
      await _initialize(f.transport);

      f.transport.receive(_readResource(1, token: 'alice-token'));
      await _settle();

      expect(f.seen, hasLength(1),
          reason: 'resources/read never reached the handler');
      expect(f.seen.single?.userId, 'alice',
          reason: 'resources would be a way around a tools-only caller wrap');
    });

    test('an anonymous request is null, not an empty caller', () async {
      final f = _boot(authenticated: false);
      addTearDown(f.server.dispose);
      await _initialize(f.transport);

      f.transport.receive(_callTool(1));
      await _settle();

      expect(f.seen, hasLength(1));
      expect(f.seen.single, isNull);
      expect(_textFor(f.transport.sent, 1), 'anonymous');
    });

    test('concurrent requests do not observe each other', () async {
      // Both handlers are held across an await so the two calls genuinely
      // overlap; sequential calls would pass even with a shared field.
      final f = _boot(toolDelay: const Duration(milliseconds: 60));
      addTearDown(f.server.dispose);
      await _initialize(f.transport);

      f.transport.receive(_callTool(1, token: 'alice-token'));
      f.transport.receive(_callTool(2, token: 'bob-token'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await _settle();

      expect(f.seen, hasLength(2));
      expect(
        f.seen.map((c) => c?.userId).toSet(),
        {'alice', 'bob'},
        reason: 'one caller overwrote the other',
      );
      expect(_textFor(f.transport.sent, 1), 'alice');
      expect(_textFor(f.transport.sent, 2), 'bob');
    });

    test('the caller does not leak outside the request', () async {
      final f = _boot();
      addTearDown(f.server.dispose);
      await _initialize(f.transport);

      f.transport.receive(_callTool(1, token: 'alice-token'));
      await _settle();

      expect(f.seen.single?.userId, 'alice');
      expect(McpCaller.current, isNull);
    });

    test('an unauthenticated call never reaches the handler', () async {
      final f = _boot();
      addTearDown(f.server.dispose);
      await _initialize(f.transport);

      f.transport.receive(_callTool(1, token: 'not-a-key'));
      await _settle();

      expect(f.seen, isEmpty,
          reason: 'a rejected request must not run the handler at all');
    });
  });
}
