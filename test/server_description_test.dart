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

Future<Map> _initializeAndCaptureServerInfo(Server server) async {
  final transport = _MockTransport();
  server.connect(transport);
  transport.receive({
    'jsonrpc': '2.0',
    'id': 1,
    'method': 'initialize',
    'params': {
      'protocolVersion': McpProtocol.v2025_11_25,
      'clientInfo': {'name': 'c', 'version': '1'},
      'capabilities': <String, dynamic>{},
    }
  });
  await Future<void>.delayed(const Duration(milliseconds: 30));
  final response = transport.sent.firstWhere(
    (m) => m is Map && m['result'] is Map && (m['result'] as Map).containsKey('serverInfo'),
  ) as Map;
  return (response['result'] as Map)['serverInfo'] as Map;
}

void main() {
  group('A9 Implementation.description', () {
    test('description emitted in serverInfo when set', () async {
      final server = Server(
        name: 'weather',
        version: '2.0.0',
        description: 'Weather lookup server',
      );
      final info = await _initializeAndCaptureServerInfo(server);
      expect(info['name'], 'weather');
      expect(info['version'], '2.0.0');
      expect(info['description'], 'Weather lookup server');
      server.dispose();
    });

    test('description omitted when not set (backward compatible)', () async {
      final server = Server(name: 'weather', version: '2.0.0');
      final info = await _initializeAndCaptureServerInfo(server);
      expect(info.containsKey('description'), isFalse);
      server.dispose();
    });

    test('McpServerConfig.createServer forwards description', () async {
      final server = McpServer.createServer(const McpServerConfig(
        name: 'cfg',
        version: '1.0.0',
        description: 'from config',
      ));
      final info = await _initializeAndCaptureServerInfo(server);
      expect(info['description'], 'from config');
      server.dispose();
    });
  });
}
