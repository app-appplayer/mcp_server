/// Unit-level pure-logic coverage for `lib/src/protocol/multi_round_trip.dart`
/// — `McpResultType`, `InputRequiredResult` (toJson/fromJson/builders),
/// `McpMrtr` reserved-key readers, and `SubscriptionFilter`
/// (toJson/fromJson/allows/isEmpty/honoredBy). Complements the real-wire MRTR
/// + subscriptions/listen e2e coverage in
/// `test/stateless_mrtr_subscriptions_test.dart`, which drives the server via
/// the client package's own `SubscriptionFilter` type rather than this one.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

void main() {
  group('McpResultType', () {
    test('discriminator constants match the draft schema', () {
      expect(McpResultType.key, 'resultType');
      expect(McpResultType.complete, 'complete');
      expect(McpResultType.inputRequired, 'input_required');
      expect(McpResultType.task, 'task');
    });
  });

  group('InputRequiredResult', () {
    test('requires inputRequests or requestState', () {
      expect(() => InputRequiredResult(), throwsA(isA<AssertionError>()));
    });

    test('toJson with inputRequests only', () {
      final r = InputRequiredResult(inputRequests: {
        'ask': {
          'method': 'elicitation/create',
          'params': <String, dynamic>{'message': 'hi'},
        },
      });
      final json = r.toJson();
      expect(json['resultType'], 'input_required');
      expect(json.containsKey('requestState'), isFalse);
      expect((json['inputRequests'] as Map)['ask']['method'],
          'elicitation/create');
    });

    test('toJson with requestState only (load-shedding)', () {
      final r = InputRequiredResult(requestState: 'opaque-blob');
      final json = r.toJson();
      expect(json['resultType'], 'input_required');
      expect(json.containsKey('inputRequests'), isFalse);
      expect(json['requestState'], 'opaque-blob');
    });

    test('fromJson parses inputRequests and requestState back', () {
      final json = {
        'resultType': 'input_required',
        'inputRequests': {
          'ask-name': {
            'method': 'elicitation/create',
            'params': {'message': 'Name?'},
          },
        },
        'requestState': 'state-v1',
      };
      final r = InputRequiredResult.fromJson(json);
      expect(r.requestState, 'state-v1');
      expect(r.inputRequests, isNotNull);
      expect(r.inputRequests!['ask-name']!['method'], 'elicitation/create');
    });

    test('fromJson with absent inputRequests yields null (not empty map)',
        () {
      final r = InputRequiredResult.fromJson({'requestState': 'x'});
      expect(r.inputRequests, isNull);
    });

    test('fromJson skips non-map values inside inputRequests', () {
      final r = InputRequiredResult.fromJson({
        'requestState': 'x',
        'inputRequests': {
          'ok': {'method': 'roots/list'},
          'bad': 'not-a-map',
        },
      });
      expect(r.inputRequests!.containsKey('ok'), isTrue);
      expect(r.inputRequests!.containsKey('bad'), isFalse);
    });

    test('elicitRequest builds an elicitation/create input-request object',
        () {
      final req = InputRequiredResult.elicitRequest(
        message: 'What is your name?',
        requestedSchema: {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
          },
        },
      );
      expect(req['method'], 'elicitation/create');
      expect(req['params']['message'], 'What is your name?');
      expect(req['params']['requestedSchema']['type'], 'object');
    });

    test('samplingRequest builds a sampling/createMessage input-request '
        'object', () {
      final req = InputRequiredResult.samplingRequest({'maxTokens': 10});
      expect(req['method'], 'sampling/createMessage');
      expect(req['params'], {'maxTokens': 10});
    });

    test('rootsRequest builds a roots/list input-request object with empty '
        'params', () {
      final req = InputRequiredResult.rootsRequest();
      expect(req['method'], 'roots/list');
      expect(req['params'], <String, dynamic>{});
    });
  });

  group('McpMrtr reserved argument keys', () {
    test('reverse-DNS key constants', () {
      expect(McpMrtr.argInputResponses, 'io.modelcontextprotocol/inputResponses');
      expect(McpMrtr.argRequestState, 'io.modelcontextprotocol/requestState');
    });

    test('readInputResponses returns the injected map when present', () {
      final args = {
        McpMrtr.argInputResponses: {
          'ask-name': {'action': 'accept', 'content': {'name': 'Ada'}},
        },
      };
      final responses = McpMrtr.readInputResponses(args);
      expect(responses, isNotNull);
      expect(responses!['ask-name']['action'], 'accept');
    });

    test('readInputResponses returns null when absent or wrong type', () {
      expect(McpMrtr.readInputResponses(const {}), isNull);
      expect(
          McpMrtr.readInputResponses(
              {McpMrtr.argInputResponses: 'not-a-map'}),
          isNull);
    });

    test('readRequestState returns the injected string when present', () {
      final args = {McpMrtr.argRequestState: 'opaque-v1'};
      expect(McpMrtr.readRequestState(args), 'opaque-v1');
    });

    test('readRequestState returns null when absent or wrong type', () {
      expect(McpMrtr.readRequestState(const {}), isNull);
      expect(McpMrtr.readRequestState({McpMrtr.argRequestState: 7}), isNull);
    });
  });

  group('SubscriptionFilter', () {
    test('default constructor is empty', () {
      const filter = SubscriptionFilter();
      expect(filter.isEmpty, isTrue);
      expect(filter.toJson(), <String, dynamic>{});
    });

    test('toJson emits only true booleans and non-empty subscriptions', () {
      const filter = SubscriptionFilter(
        toolsListChanged: true,
        promptsListChanged: false,
        resourcesListChanged: true,
        resourceSubscriptions: ['file:///a', 'file:///b'],
      );
      final json = filter.toJson();
      expect(json['toolsListChanged'], true);
      expect(json.containsKey('promptsListChanged'), isFalse);
      expect(json['resourcesListChanged'], true);
      expect(json['resourceSubscriptions'], ['file:///a', 'file:///b']);
      expect(filter.isEmpty, isFalse);
    });

    test('fromJson parses booleans and stringifies subscription URIs', () {
      final filter = SubscriptionFilter.fromJson({
        'toolsListChanged': true,
        'resourcesListChanged': true,
        'resourceSubscriptions': ['file:///watched', 42],
      });
      expect(filter.toolsListChanged, isTrue);
      expect(filter.promptsListChanged, isFalse);
      expect(filter.resourcesListChanged, isTrue);
      expect(filter.resourceSubscriptions, ['file:///watched', '42']);
    });

    test('fromJson defaults to empty when resourceSubscriptions is absent '
        'or not a list', () {
      final a = SubscriptionFilter.fromJson(const {});
      expect(a.resourceSubscriptions, isEmpty);
      final b = SubscriptionFilter.fromJson({'resourceSubscriptions': 'x'});
      expect(b.resourceSubscriptions, isEmpty);
    });

    test('allows() dispatches on the notification method', () {
      const filter = SubscriptionFilter(
        toolsListChanged: true,
        promptsListChanged: true,
        resourcesListChanged: false,
        resourceSubscriptions: ['file:///a'],
      );
      expect(filter.allows('notifications/tools/list_changed'), isTrue);
      expect(filter.allows('notifications/prompts/list_changed'), isTrue);
      expect(filter.allows('notifications/resources/list_changed'), isFalse);
      expect(
          filter.allows('notifications/resources/updated', uri: 'file:///a'),
          isTrue);
      expect(
          filter.allows('notifications/resources/updated', uri: 'file:///b'),
          isFalse);
      expect(filter.allows('notifications/resources/updated'), isFalse);
      expect(filter.allows('notifications/unknown/method'), isFalse);
    });

    test('honoredBy drops unsupported types and clears subscriptions when '
        'resources are unsupported', () {
      const filter = SubscriptionFilter(
        toolsListChanged: true,
        promptsListChanged: true,
        resourcesListChanged: true,
        resourceSubscriptions: ['file:///a'],
      );
      final honored = filter.honoredBy(
        hasTools: true,
        hasPrompts: false,
        hasResources: false,
      );
      expect(honored.toolsListChanged, isTrue);
      expect(honored.promptsListChanged, isFalse);
      expect(honored.resourcesListChanged, isFalse);
      expect(honored.resourceSubscriptions, isEmpty);
    });

    test('honoredBy keeps resourceSubscriptions when resources are '
        'supported', () {
      const filter = SubscriptionFilter(
        resourcesListChanged: true,
        resourceSubscriptions: ['file:///a', 'file:///b'],
      );
      final honored = filter.honoredBy(
        hasTools: false,
        hasPrompts: false,
        hasResources: true,
      );
      expect(honored.resourcesListChanged, isTrue);
      expect(honored.resourceSubscriptions, ['file:///a', 'file:///b']);
    });
  });
}
