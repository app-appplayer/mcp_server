import 'dart:async';

import 'package:mcp_server/mcp_server.dart';
import 'package:test/test.dart';

/// Mock transport capturing outbound messages and allowing injection of
/// inbound ones.
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

void main() {
  group('A4 sampling tools / toolChoice', () {
    test('CreateMessageRequest round-trips tools and toolChoice', () {
      final req = CreateMessageRequest(
        messages: [
          Message(role: 'user', content: TextContent(text: 'hi')),
        ],
        maxTokens: 100,
        tools: [
          SamplingTool(
            name: 'get_weather',
            description: 'Look up the weather',
            inputSchema: {
              'type': 'object',
              'properties': {
                'city': {'type': 'string'}
              },
              'required': ['city'],
            },
          ),
        ],
        toolChoice: const ToolChoice.tool('get_weather'),
      );

      final json = req.toJson();
      expect(json['tools'], isA<List>());
      expect((json['tools'] as List).single['name'], 'get_weather');
      expect((json['tools'] as List).single['inputSchema']['type'], 'object');
      expect(json['toolChoice'], {'type': 'tool', 'name': 'get_weather'});

      final back = CreateMessageRequest.fromJson(json);
      expect(back.tools, hasLength(1));
      expect(back.tools!.single.name, 'get_weather');
      expect(back.tools!.single.description, 'Look up the weather');
      expect(back.toolChoice!.type, 'tool');
      expect(back.toolChoice!.name, 'get_weather');
      // Full structural equality of the re-serialized form.
      expect(back.toJson(), json);
    });

    test('ToolChoice enumerated modes serialize correctly', () {
      expect(const ToolChoice.auto().toJson(), {'type': 'auto'});
      expect(const ToolChoice.any().toJson(), {'type': 'any'});
      expect(const ToolChoice.none().toJson(), {'type': 'none'});
      expect(ToolChoice.fromJson({'type': 'auto'}).name, isNull);
    });

    test('omitting tools/toolChoice keeps them off the wire', () {
      final req = CreateMessageRequest(
        messages: [Message(role: 'user', content: TextContent(text: 'hi'))],
        maxTokens: 10,
      );
      final json = req.toJson();
      expect(json.containsKey('tools'), isFalse);
      expect(json.containsKey('toolChoice'), isFalse);
    });

    test('requestClientSampling carries tools/toolChoice through to the wire',
        () async {
      final server = Server(
        name: 'test',
        version: '1.0.0',
        capabilities: ServerCapabilities.simple(tools: true),
      );
      final transport = _MockTransport();
      server.connect(transport);

      // Initialize with 2025-11-25 + sampling capability.
      transport.receive({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': McpProtocol.v2025_11_25,
          'clientInfo': {'name': 'c', 'version': '1'},
          'capabilities': {'sampling': <String, dynamic>{}},
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final sessionId = server.getSessions().first.id;

      final req = CreateMessageRequest(
        messages: [Message(role: 'user', content: TextContent(text: 'go'))],
        maxTokens: 50,
        tools: [
          SamplingTool(name: 'calc', inputSchema: {'type': 'object'}),
        ],
        toolChoice: const ToolChoice.any(),
      );

      final future = server.requestClientSampling(sessionId, req.toJson());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Find the outbound sampling/createMessage request.
      final outbound = transport.sent.firstWhere(
        (m) => m is Map && m['method'] == 'sampling/createMessage',
      ) as Map;
      final params = outbound['params'] as Map;
      expect((params['tools'] as List).single['name'], 'calc');
      expect(params['toolChoice'], {'type': 'any'});

      // Complete the outbound request so the future resolves.
      transport.receive({
        'jsonrpc': '2.0',
        'id': outbound['id'],
        'result': {
          'role': 'assistant',
          'model': 'test-model',
          'content': {'type': 'text', 'text': 'done'},
        }
      });

      final result = await future;
      expect(result['model'], 'test-model');

      server.dispose();
    });
  });
}
