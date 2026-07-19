/// Pure-logic coverage for the Tool/Resource/Prompt model classes in
/// `lib/src/models/models.dart` — `Tool`, `ResourceTemplate`, `Resource`,
/// `ResourceContentInfo`, `ReadResourceResult`, `PromptArgument`, `Prompt`,
/// `Message`, and `GetPromptResult`, each round-tripped through
/// `toJson`/`fromJson` where available.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

void main() {
  group('Tool', () {
    test('toJson with only required fields', () {
      const tool = Tool(
        name: 'echo',
        description: 'echoes input',
        inputSchema: {'type': 'object'},
      );
      final json = tool.toJson();
      expect(json, {
        'name': 'echo',
        'description': 'echoes input',
        'inputSchema': {'type': 'object'},
      });
    });

    test('toJson with every optional field', () {
      const tool = Tool(
        name: 'echo',
        title: 'Echo Tool',
        description: 'echoes input',
        inputSchema: {'type': 'object'},
        outputSchema: {'type': 'object'},
        icons: [
          {'src': 'https://example.com/icon.png'}
        ],
        meta: {'io.example/x': 1},
        supportsProgress: true,
        supportsCancellation: true,
        metadata: {'category': 'utility'},
      );
      final json = tool.toJson();
      expect(json['title'], 'Echo Tool');
      expect(json['outputSchema'], {'type': 'object'});
      expect(json['icons'], [
        {'src': 'https://example.com/icon.png'}
      ]);
      expect(json['_meta'], {'io.example/x': 1});
      expect(json['supportsProgress'], true);
      expect(json['supportsCancellation'], true);
      expect(json['metadata'], {'category': 'utility'});
    });

    test('toJson omits supportsProgress/supportsCancellation when false', () {
      const tool = Tool(
        name: 'echo',
        description: 'x',
        inputSchema: {},
        supportsProgress: false,
        supportsCancellation: false,
      );
      final json = tool.toJson();
      expect(json.containsKey('supportsProgress'), isFalse);
      expect(json.containsKey('supportsCancellation'), isFalse);
    });

    test('fromJson round-trip with every field', () {
      final json = {
        'name': 'echo',
        'title': 'Echo Tool',
        'description': 'echoes input',
        'inputSchema': {'type': 'object'},
        'outputSchema': {'type': 'string'},
        'icons': [
          {'src': 'https://example.com/icon.png', 'sizes': '48x48'}
        ],
        '_meta': {'io.example/x': 1},
        'supportsProgress': true,
        'supportsCancellation': false,
        'metadata': {'category': 'utility'},
      };
      final tool = Tool.fromJson(json);
      expect(tool.name, 'echo');
      expect(tool.title, 'Echo Tool');
      expect(tool.description, 'echoes input');
      expect(tool.inputSchema, {'type': 'object'});
      expect(tool.outputSchema, {'type': 'string'});
      expect(tool.icons, [
        {'src': 'https://example.com/icon.png', 'sizes': '48x48'}
      ]);
      expect(tool.meta, {'io.example/x': 1});
      expect(tool.supportsProgress, isTrue);
      expect(tool.supportsCancellation, isFalse);
      expect(tool.metadata, {'category': 'utility'});
    });

    test('fromJson with only required fields leaves optionals null', () {
      final tool = Tool.fromJson({
        'name': 'x',
        'description': 'd',
        'inputSchema': <String, dynamic>{},
      });
      expect(tool.title, isNull);
      expect(tool.outputSchema, isNull);
      expect(tool.icons, isNull);
      expect(tool.meta, isNull);
    });
  });

  group('CallToolResult', () {
    test('toJson default isStreaming false, no structuredContent/isError',
        () {
      final result = CallToolResult(content: [const TextContent(text: 'ok')]);
      final json = result.toJson();
      expect(json['isStreaming'], isFalse);
      expect(json.containsKey('structuredContent'), isFalse);
      expect(json.containsKey('isError'), isFalse);
    });

    test('toJson with structuredContent, isStreaming, and isError', () {
      final result = CallToolResult(
        content: [const TextContent(text: 'partial')],
        structuredContent: {'value': 42},
        isStreaming: true,
        isError: true,
      );
      final json = result.toJson();
      expect(json['structuredContent'], {'value': 42});
      expect(json['isStreaming'], isTrue);
      expect(json['isError'], isTrue);
      expect((json['content'] as List).single, {'type': 'text', 'text': 'partial'});
    });
  });

  group('ResourceTemplate', () {
    test('toJson with only required fields', () {
      const t = ResourceTemplate(
        uriTemplate: 'file:///{path}',
        name: 'files',
        description: 'file system access',
      );
      expect(t.toJson(), {
        'uriTemplate': 'file:///{path}',
        'name': 'files',
        'description': 'file system access',
      });
    });

    test('toJson with every optional field', () {
      const t = ResourceTemplate(
        uriTemplate: 'file:///{path}',
        name: 'files',
        title: 'Files',
        description: 'file system access',
        mimeType: 'text/plain',
        icons: [
          {'src': 'icon.png'}
        ],
        meta: {'io.example/x': 1},
      );
      final json = t.toJson();
      expect(json['title'], 'Files');
      expect(json['mimeType'], 'text/plain');
      expect(json['icons'], [
        {'src': 'icon.png'}
      ]);
      expect(json['_meta'], {'io.example/x': 1});
    });

    test('fromJson round-trip', () {
      final json = {
        'uriTemplate': 'file:///{path}',
        'name': 'files',
        'title': 'Files',
        'description': 'file system access',
        'mimeType': 'text/plain',
        'icons': [
          {'src': 'icon.png'}
        ],
        '_meta': {'io.example/x': 1},
      };
      final t = ResourceTemplate.fromJson(json);
      expect(t.uriTemplate, 'file:///{path}');
      expect(t.title, 'Files');
      expect(t.mimeType, 'text/plain');
      expect(t.icons, [
        {'src': 'icon.png'}
      ]);
      expect(t.meta, {'io.example/x': 1});
    });

    test('fromJson with only required fields leaves optionals null', () {
      final t = ResourceTemplate.fromJson({
        'uriTemplate': 'x',
        'name': 'n',
        'description': 'd',
      });
      expect(t.title, isNull);
      expect(t.mimeType, isNull);
      expect(t.icons, isNull);
      expect(t.meta, isNull);
    });
  });

  group('Resource', () {
    test('toJson with only required fields', () {
      final r = Resource(
        uri: 'file:///a.txt',
        name: 'a',
        description: 'text file',
        mimeType: 'text/plain',
      );
      expect(r.toJson(), {
        'uri': 'file:///a.txt',
        'name': 'a',
        'description': 'text file',
        'mimeType': 'text/plain',
      });
    });

    test('toJson with every optional field', () {
      final r = Resource(
        uri: 'file:///a.txt',
        name: 'a',
        title: 'A',
        description: 'text file',
        mimeType: 'text/plain',
        uriTemplate: {'template': 'file:///{name}'},
        icons: [
          {'src': 'icon.png'}
        ],
        meta: {'io.example/x': 1},
      );
      final json = r.toJson();
      expect(json['title'], 'A');
      expect(json['uriTemplate'], {'template': 'file:///{name}'});
      expect(json['icons'], [
        {'src': 'icon.png'}
      ]);
      expect(json['_meta'], {'io.example/x': 1});
    });
  });

  group('ResourceContentInfo', () {
    test('toJson with only uri', () {
      final c = ResourceContentInfo(uri: 'file:///a.txt');
      expect(c.toJson(), {'uri': 'file:///a.txt'});
    });

    test('toJson with all fields, fromJson round-trip', () {
      final c = ResourceContentInfo(
        uri: 'file:///a.txt',
        mimeType: 'text/plain',
        text: 'hello',
        blob: null,
      );
      final json = c.toJson();
      expect(json, {
        'uri': 'file:///a.txt',
        'mimeType': 'text/plain',
        'text': 'hello',
      });
      final back = ResourceContentInfo.fromJson(json);
      expect(back.uri, 'file:///a.txt');
      expect(back.mimeType, 'text/plain');
      expect(back.text, 'hello');
      expect(back.blob, isNull);
    });

    test('toJson / fromJson with blob field', () {
      final c = ResourceContentInfo(uri: 'file:///a.bin', blob: 'YmluYXJ5');
      final json = c.toJson();
      expect(json['blob'], 'YmluYXJ5');
      final back = ResourceContentInfo.fromJson(json);
      expect(back.blob, 'YmluYXJ5');
    });
  });

  group('ReadResourceResult', () {
    test('toJson / fromJson round-trip with contents', () {
      final result = ReadResourceResult(contents: [
        ResourceContentInfo(uri: 'file:///a.txt', text: 'hi'),
      ]);
      final json = result.toJson();
      expect((json['contents'] as List), hasLength(1));

      final back = ReadResourceResult.fromJson(json);
      expect(back.contents, hasLength(1));
      expect(back.contents.single.uri, 'file:///a.txt');
      expect(back.contents.single.text, 'hi');
    });

    test('fromJson defaults to an empty list when contents is absent', () {
      final back = ReadResourceResult.fromJson(const {});
      expect(back.contents, isEmpty);
    });
  });

  group('PromptArgument', () {
    test('toJson with required=false and no default', () {
      final arg = PromptArgument(name: 'x', description: 'the x arg');
      expect(arg.toJson(), {
        'name': 'x',
        'description': 'the x arg',
        'required': false,
      });
    });

    test('toJson with a default value', () {
      final arg = PromptArgument(
        name: 'x',
        description: 'the x arg',
        required: true,
        defaultValue: '42',
      );
      final json = arg.toJson();
      expect(json['required'], isTrue);
      expect(json['default'], '42');
    });

    test('fromJson with all fields present', () {
      final arg = PromptArgument.fromJson({
        'name': 'x',
        'description': 'the x arg',
        'required': true,
        'default': '42',
      });
      expect(arg.name, 'x');
      expect(arg.description, 'the x arg');
      expect(arg.required, isTrue);
      expect(arg.defaultValue, '42');
    });

    test('fromJson defaults description/required when absent', () {
      final arg = PromptArgument.fromJson({'name': 'x'});
      expect(arg.description, '');
      expect(arg.required, isFalse);
      expect(arg.defaultValue, isNull);
    });
  });

  group('Prompt', () {
    test('toJson with only required fields', () {
      final prompt = Prompt(
        name: 'greet',
        description: 'greets the user',
        arguments: [PromptArgument(name: 'name', description: 'their name')],
      );
      final json = prompt.toJson();
      expect(json['name'], 'greet');
      expect(json.containsKey('title'), isFalse);
      expect((json['arguments'] as List), hasLength(1));
      expect(json.containsKey('icons'), isFalse);
      expect(json.containsKey('_meta'), isFalse);
    });

    test('toJson with every optional field', () {
      final prompt = Prompt(
        name: 'greet',
        title: 'Greet',
        description: 'greets the user',
        arguments: const [],
        icons: [
          {'src': 'icon.png'}
        ],
        meta: {'io.example/x': 1},
      );
      final json = prompt.toJson();
      expect(json['title'], 'Greet');
      expect(json['icons'], [
        {'src': 'icon.png'}
      ]);
      expect(json['_meta'], {'io.example/x': 1});
    });
  });

  group('Message', () {
    test('toJson / fromJson round-trip', () {
      final message = Message(
        role: 'user',
        content: const TextContent(text: 'hi'),
      );
      final json = message.toJson();
      expect(json, {
        'role': 'user',
        'content': {'type': 'text', 'text': 'hi'},
      });
      final back = Message.fromJson(json);
      expect(back.role, 'user');
      expect((back.content as TextContent).text, 'hi');
    });
  });

  group('GetPromptResult', () {
    test('toJson serializes description and messages', () {
      final result = GetPromptResult(
        description: 'a greeting prompt',
        messages: [
          Message(role: 'user', content: const TextContent(text: 'hi')),
        ],
      );
      final json = result.toJson();
      expect(json['description'], 'a greeting prompt');
      expect((json['messages'] as List), hasLength(1));
    });
  });
}
