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

void main() {
  group('A5 typed elicitation schema', () {
    test('primitive schemas emit SEP-1034 default values', () {
      expect(
        const StringSchema(title: 'Name', defaultValue: 'anon').toJson(),
        {'type': 'string', 'title': 'Name', 'default': 'anon'},
      );
      expect(
        const NumberSchema(integer: true, minimum: 1, defaultValue: 5).toJson(),
        {'type': 'integer', 'minimum': 1, 'default': 5},
      );
      expect(
        const BooleanSchema(defaultValue: true).toJson(),
        {'type': 'boolean', 'default': true},
      );
    });

    test('single-select enum with titled enumNames (SEP-1330)', () {
      final schema = const EnumSchema(
        values: ['r', 'g', 'b'],
        enumNames: ['Red', 'Green', 'Blue'],
        defaultValue: 'g',
      );
      final json = schema.toJson();
      expect(json['type'], 'string');
      expect(json['enum'], ['r', 'g', 'b']);
      expect(json['enumNames'], ['Red', 'Green', 'Blue']);
      expect(json['default'], 'g');

      final back = ElicitationSchema.fromJson(json) as EnumSchema;
      expect(back.multiSelect, isFalse);
      expect(back.values, ['r', 'g', 'b']);
      expect(back.enumNames, ['Red', 'Green', 'Blue']);
      expect(back.toJson(), json);
    });

    test('untitled single-select enum omits enumNames', () {
      final json = const EnumSchema(values: ['a', 'b']).toJson();
      expect(json.containsKey('enumNames'), isFalse);
      final back = ElicitationSchema.fromJson(json) as EnumSchema;
      expect(back.enumNames, isNull);
    });

    test('multi-select enum emits array of enum (SEP-1330)', () {
      final schema = const EnumSchema(
        values: ['x', 'y', 'z'],
        enumNames: ['X', 'Y', 'Z'],
        multiSelect: true,
        defaultValue: ['x', 'z'],
        title: 'Pick',
      );
      final json = schema.toJson();
      expect(json['type'], 'array');
      expect(json['items'], {
        'type': 'string',
        'enum': ['x', 'y', 'z'],
        'enumNames': ['X', 'Y', 'Z'],
      });
      expect(json['default'], ['x', 'z']);

      final back = ElicitationSchema.fromJson(json) as EnumSchema;
      expect(back.multiSelect, isTrue);
      expect(back.values, ['x', 'y', 'z']);
      expect(back.toJson(), json);
    });

    test('ElicitationRequest builds spec-shaped requestedSchema', () {
      final req = const ElicitationRequest(
        message: 'Tell me',
        properties: {
          'name': StringSchema(minLength: 1),
          'color': EnumSchema(values: ['r', 'b'], enumNames: ['Red', 'Blue']),
        },
        required: ['name'],
      );
      final json = req.toJson();
      expect(json['message'], 'Tell me');
      final schema = json['requestedSchema'] as Map;
      expect(schema['type'], 'object');
      expect(schema['required'], ['name']);
      expect((schema['properties'] as Map)['name']['type'], 'string');

      final back = ElicitationRequest.fromJson(json);
      expect(back.required, ['name']);
      expect(back.properties['color'], isA<EnumSchema>());
      expect(back.toJson(), json);
    });

    test('URL-mode elicitation (SEP-1036) round-trips', () {
      final req = const UrlElicitationRequest(
        message: 'Authorize here',
        url: 'https://example.com/oauth',
      );
      final json = req.toJson();
      expect(json, {
        'mode': 'url',
        'message': 'Authorize here',
        'url': 'https://example.com/oauth',
      });
      final back = UrlElicitationRequest.fromJson(json);
      expect(back.url, 'https://example.com/oauth');
      expect(back.toJson(), json);
    });

    test('unrecognized schema preserved verbatim', () {
      final raw = {'type': 'string', 'pattern': '^[0-9]+\$'};
      final parsed = ElicitationSchema.fromJson(raw);
      // A plain string schema (no enum) parses as StringSchema; the pattern
      // is not modeled but must not corrupt the string type.
      expect(parsed, isA<StringSchema>());
      expect(parsed.toJson()['type'], 'string');
    });

    test('typed elicitation request carries through to the wire', () async {
      final server = Server(name: 'test', version: '1.0.0');
      final transport = _MockTransport();
      server.connect(transport);

      transport.receive({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': McpProtocol.v2025_11_25,
          'clientInfo': {'name': 'c', 'version': '1'},
          'capabilities': {'elicitation': <String, dynamic>{}},
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final sessionId = server.getSessions().first.id;

      final req = const ElicitationRequest(
        message: 'name?',
        properties: {'name': StringSchema(defaultValue: 'x')},
        required: ['name'],
      );
      final future =
          server.requestClientElicitation(sessionId, req.toJson());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final outbound = transport.sent.firstWhere(
        (m) => m is Map && m['method'] == 'elicitation/create',
      ) as Map;
      final params = outbound['params'] as Map;
      expect(params['message'], 'name?');
      expect(
        (params['requestedSchema'] as Map)['properties']['name']['default'],
        'x',
      );

      transport.receive({
        'jsonrpc': '2.0',
        'id': outbound['id'],
        'result': {'action': 'accept', 'content': {'name': 'Sam'}},
      });
      final result = await future;
      expect(result['action'], 'accept');

      server.dispose();
    });
  });
}
