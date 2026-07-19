/// Pure-logic coverage for the sampling model classes in
/// `lib/src/models/models.dart` — `ModelHint`, `ModelPreferences`,
/// `CreateMessageRequest` (every optional field branch of toJson/fromJson,
/// beyond the tools/toolChoice-focused coverage in
/// `test/sampling_tools_toolchoice_test.dart`), and `CreateMessageResult`
/// (toJson plus every fromJson content-type branch, including the unknown
/// content type throw).
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

void main() {
  group('ModelHint', () {
    test('toJson without weight', () {
      final hint = ModelHint(name: 'claude-3');
      expect(hint.toJson(), {'name': 'claude-3'});
    });

    test('toJson with weight, fromJson round-trip', () {
      final hint = ModelHint(name: 'claude-3', weight: '0.8');
      final json = hint.toJson();
      expect(json, {'name': 'claude-3', 'weight': '0.8'});
      final back = ModelHint.fromJson(json);
      expect(back.name, 'claude-3');
      expect(back.weight, '0.8');
    });
  });

  group('ModelPreferences', () {
    test('toJson omits everything when all fields are absent/empty', () {
      final prefs = ModelPreferences();
      expect(prefs.toJson(), <String, dynamic>{});
    });

    test('toJson with hints and all priorities set, fromJson round-trip',
        () {
      final prefs = ModelPreferences(
        hints: [ModelHint(name: 'claude-3'), ModelHint(name: 'gpt-4')],
        intelligencePriority: 0.9,
        speedPriority: 0.2,
        costPriority: 0.1,
      );
      final json = prefs.toJson();
      expect((json['hints'] as List), hasLength(2));
      expect(json['intelligencePriority'], 0.9);
      expect(json['speedPriority'], 0.2);
      expect(json['costPriority'], 0.1);

      final back = ModelPreferences.fromJson(json);
      expect(back.hints, hasLength(2));
      expect(back.hints!.first.name, 'claude-3');
      expect(back.intelligencePriority, 0.9);
      expect(back.speedPriority, 0.2);
      expect(back.costPriority, 0.1);
    });

    test('an empty hints list is omitted from toJson', () {
      final prefs = ModelPreferences(hints: const []);
      expect(prefs.toJson().containsKey('hints'), isFalse);
    });

    test('fromJson with no fields present leaves everything null', () {
      final prefs = ModelPreferences.fromJson(const {});
      expect(prefs.hints, isNull);
      expect(prefs.intelligencePriority, isNull);
      expect(prefs.speedPriority, isNull);
      expect(prefs.costPriority, isNull);
    });

    test('fromJson accepts integer priority values and converts to double',
        () {
      final prefs = ModelPreferences.fromJson({
        'intelligencePriority': 1,
        'speedPriority': 0,
      });
      expect(prefs.intelligencePriority, 1.0);
      expect(prefs.speedPriority, 0.0);
    });
  });

  group('CreateMessageRequest — full optional-field coverage', () {
    test('toJson with every optional field populated', () {
      final req = CreateMessageRequest(
        messages: [Message(role: 'user', content: const TextContent(text: 'hi'))],
        modelPreferences: ModelPreferences(costPriority: 0.5),
        systemPrompt: 'You are helpful.',
        includeContext: 'thisServer',
        maxTokens: 200,
        temperature: 0.7,
        stopSequences: ['STOP', 'END'],
        metadata: {'trace': 'abc'},
      );
      final json = req.toJson();
      expect(json['modelPreferences'], {'costPriority': 0.5});
      expect(json['systemPrompt'], 'You are helpful.');
      expect(json['includeContext'], 'thisServer');
      expect(json['maxTokens'], 200);
      expect(json['temperature'], 0.7);
      expect(json['stopSequences'], ['STOP', 'END']);
      expect(json['metadata'], {'trace': 'abc'});
      expect(json.containsKey('tools'), isFalse);
      expect(json.containsKey('toolChoice'), isFalse);
    });

    test('fromJson round-trip with every optional field', () {
      final json = {
        'messages': [
          {
            'role': 'user',
            'content': {'type': 'text', 'text': 'hi'},
          }
        ],
        'modelPreferences': {'costPriority': 0.5},
        'systemPrompt': 'You are helpful.',
        'includeContext': 'thisServer',
        'maxTokens': 200,
        'temperature': 0.7,
        'stopSequences': ['STOP', 'END'],
        'metadata': {'trace': 'abc'},
      };
      final req = CreateMessageRequest.fromJson(json);
      expect(req.messages, hasLength(1));
      expect(req.modelPreferences!.costPriority, 0.5);
      expect(req.systemPrompt, 'You are helpful.');
      expect(req.includeContext, 'thisServer');
      expect(req.maxTokens, 200);
      expect(req.temperature, 0.7);
      expect(req.stopSequences, ['STOP', 'END']);
      expect(req.metadata, {'trace': 'abc'});
      expect(req.tools, isNull);
      expect(req.toolChoice, isNull);
    });

    test('fromJson with only required fields leaves optionals null', () {
      final req = CreateMessageRequest.fromJson({
        'messages': [
          {
            'role': 'user',
            'content': {'type': 'text', 'text': 'hi'},
          }
        ],
      });
      expect(req.modelPreferences, isNull);
      expect(req.systemPrompt, isNull);
      expect(req.includeContext, isNull);
      expect(req.maxTokens, isNull);
      expect(req.temperature, isNull);
      expect(req.stopSequences, isNull);
      expect(req.metadata, isNull);
    });
  });

  group('CreateMessageResult', () {
    test('toJson without stopReason', () {
      final result = CreateMessageResult(
        model: 'claude-3',
        role: 'assistant',
        content: const TextContent(text: 'hi there'),
      );
      final json = result.toJson();
      expect(json, {
        'model': 'claude-3',
        'role': 'assistant',
        'content': {'type': 'text', 'text': 'hi there'},
      });
    });

    test('toJson with stopReason', () {
      final result = CreateMessageResult(
        model: 'claude-3',
        stopReason: 'endTurn',
        role: 'assistant',
        content: const TextContent(text: 'done'),
      );
      expect(result.toJson()['stopReason'], 'endTurn');
    });

    test('fromJson parses a text content result', () {
      final result = CreateMessageResult.fromJson({
        'model': 'claude-3',
        'stopReason': 'endTurn',
        'role': 'assistant',
        'content': {'type': 'text', 'text': 'hi'},
      });
      expect(result.model, 'claude-3');
      expect(result.stopReason, 'endTurn');
      expect(result.role, 'assistant');
      expect(result.content, isA<TextContent>());
      expect((result.content as TextContent).text, 'hi');
    });

    test('fromJson parses an image content result', () {
      final result = CreateMessageResult.fromJson({
        'model': 'claude-3',
        'role': 'assistant',
        'content': {
          'type': 'image',
          'url': 'https://example.com/i.png',
          'mimeType': 'image/png',
        },
      });
      expect(result.content, isA<ImageContent>());
      final img = result.content as ImageContent;
      expect(img.url, 'https://example.com/i.png');
      expect(img.mimeType, 'image/png');
    });

    test('fromJson parses a resource content result', () {
      final result = CreateMessageResult.fromJson({
        'model': 'claude-3',
        'role': 'assistant',
        'content': {
          'type': 'resource',
          'uri': 'file:///a.txt',
          'text': 'file body',
          'blob': null,
        },
      });
      expect(result.content, isA<ResourceContent>());
      final res = result.content as ResourceContent;
      expect(res.uri, 'file:///a.txt');
      expect(res.text, 'file body');
    });

    test('fromJson throws FormatException for an unknown content type', () {
      expect(
        () => CreateMessageResult.fromJson({
          'model': 'claude-3',
          'role': 'assistant',
          'content': {'type': 'video'},
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
