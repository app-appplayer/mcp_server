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

Server _serverWithTool({Map<String, dynamic>? inputSchema}) {
  final server = Server(
    name: 't',
    version: '1',
    capabilities: ServerCapabilities.simple(tools: true),
  );
  server.addTool(
    name: 'echo',
    description: 'echo',
    inputSchema: inputSchema ??
        {
          'type': 'object',
          'properties': {
            'msg': {'type': 'string'}
          },
        },
    handler: (args) async => CallToolResult(content: [TextContent(text: 'ok')]),
  );
  return server;
}

Future<List> _listTools(Server server, String version) async {
  final transport = _MockTransport();
  server.connect(transport);
  transport.receive({
    'jsonrpc': '2.0',
    'id': 1,
    'method': 'initialize',
    'params': {
      'protocolVersion': version,
      'clientInfo': {'name': 'c', 'version': '1'},
      'capabilities': <String, dynamic>{},
    }
  });
  await Future<void>.delayed(const Duration(milliseconds: 20));
  transport.receive({
    'jsonrpc': '2.0',
    'id': 2,
    'method': 'tools/list',
    'params': <String, dynamic>{},
  });
  await Future<void>.delayed(const Duration(milliseconds: 20));
  final response = transport.sent.firstWhere(
    (m) => m is Map && m['id'] == 2,
  ) as Map;
  return (response['result'] as Map)['tools'] as List;
}

void main() {
  group('A10 JSON Schema 2020-12 default dialect (SEP-1613)', () {
    test('2025-11-25 peer gets \$schema 2020-12 annotation', () async {
      final server = _serverWithTool();
      final tools = await _listTools(server, McpProtocol.v2025_11_25);
      final schema = (tools.single as Map)['inputSchema'] as Map;
      expect(schema[r'$schema'], McpProtocol.jsonSchemaDialect2020_12);
      expect(schema['type'], 'object');
      server.dispose();
    });

    test('2025-06-18 peer keeps free-form schema (no \$schema added)',
        () async {
      final server = _serverWithTool();
      final tools = await _listTools(server, McpProtocol.v2025_06_18);
      final schema = (tools.single as Map)['inputSchema'] as Map;
      expect(schema.containsKey(r'$schema'), isFalse);
      server.dispose();
    });

    test('existing \$schema on a tool is preserved unchanged', () async {
      final server = _serverWithTool(inputSchema: {
        r'$schema': 'https://json-schema.org/draft-07/schema',
        'type': 'object',
      });
      final tools = await _listTools(server, McpProtocol.v2025_11_25);
      final schema = (tools.single as Map)['inputSchema'] as Map;
      expect(schema[r'$schema'], 'https://json-schema.org/draft-07/schema');
      server.dispose();
    });

    test('withDefaultSchemaDialect helper is additive', () {
      final annotated =
          McpProtocol.withDefaultSchemaDialect({'type': 'object'});
      expect(annotated[r'$schema'], McpProtocol.jsonSchemaDialect2020_12);
      expect(annotated['type'], 'object');
      // Idempotent when already present.
      final again = McpProtocol.withDefaultSchemaDialect(annotated);
      expect(again, annotated);
    });
  });
}
