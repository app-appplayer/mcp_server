/// The caller's own credential reaches the handler.
///
/// `AuthContext.token` is a documented public field that nothing filled: the
/// credential existed only as a local inside the authentication helper, so a
/// handler could learn everything about the caller except the token they
/// presented. Eight published versions carried the gap because every test
/// asserting on `AuthContext` looked at `userId` and `scopes` and none looked
/// at `token`.
///
/// A runtime that must act *as* the caller — forwarding a request outward
/// under the caller's own grant rather than holding a credential of its own —
/// cannot work without this. Holding its own credential is the thing that
/// design exists to avoid: a runtime that can ask for "this user's data" on
/// its own authority is not isolated.
@TestOn('vm')
library;

import 'dart:async';

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

/// Two callers, so a token that leaked across requests would show up as the
/// wrong one rather than merely as null.
Map<String, Map<String, dynamic>> _keys() => {
      'alice-token': {
        'sub': 'alice',
        'scopes': ['tools:execute'],
      },
      'bob-token': {
        'sub': 'bob',
        'scopes': ['tools:execute'],
      },
    };

({Server server, _MockTransport transport, List<AuthContext?> seen}) _boot() {
  final seen = <AuthContext?>[];
  final server = Server(
    name: 'caller-token-fixture',
    version: '1.0.0',
    capabilities: ServerCapabilities.simple(tools: true),
  );
  server.addTool(
    name: 'whoami',
    description: 'Records the caller the handler observed',
    inputSchema: const {'type': 'object', 'additionalProperties': true},
    handler: (args) async {
      seen.add(McpCaller.current);
      return CallToolResult(content: [TextContent(text: 'ok')]);
    },
  );
  server.enableAuthentication(ApiKeyValidator(_keys()));
  final transport = _MockTransport();
  server.connect(transport);
  return (server: server, transport: transport, seen: seen);
}

Future<void> _settle([int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, dynamic> _call(int id, String token) => {
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/call',
      'params': {
        'name': 'whoami',
        'arguments': <String, Object?>{},
        'authorization': token,
      },
    };

void main() {
  late Server server;
  late _MockTransport transport;
  late List<AuthContext?> seen;

  setUp(() async {
    final f = _boot();
    server = f.server;
    transport = f.transport;
    seen = f.seen;
    transport.receive({
      'jsonrpc': '2.0',
      'id': 0,
      'method': 'initialize',
      'params': {
        'protocolVersion': _protocolVersion,
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'caller-token-test', 'version': '1.0.0'},
      },
    });
    await _settle();
  });

  tearDown(() => server.dispose());

  test('the handler sees the exact token the caller presented', () async {
    transport.receive(_call(1, 'alice-token'));
    await _settle();

    expect(seen, hasLength(1));
    expect(seen.single?.token, 'alice-token',
        reason: 'a handler that must act as the caller has nothing to act '
            'with unless the credential itself arrives');
  });

  test('claims and credential describe the same caller', () async {
    transport.receive(_call(1, 'bob-token'));
    await _settle();

    expect(seen.single?.userId, 'bob');
    expect(seen.single?.token, 'bob-token');
  });

  test('concurrent callers do not exchange credentials', () async {
    transport.receive(_call(1, 'alice-token'));
    transport.receive(_call(2, 'bob-token'));
    await _settle(40);

    final pairs = {
      for (final c in seen) '${c?.userId}': c?.token,
    };
    expect(pairs, {'alice': 'alice-token', 'bob': 'bob-token'},
        reason: 'a credential reaching the wrong handler is worse than none');
  });

  test('a rejected token never reaches the handler', () async {
    transport.receive(_call(1, 'not-a-key'));
    await _settle();

    expect(seen, isEmpty);
  });
}
