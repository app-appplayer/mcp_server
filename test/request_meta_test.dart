/// 2026-07-28 stateless core (SEP-2577) — reverse-DNS `_meta` key helpers.
///
/// Verifies the typed read/write of the four request keys and the serverInfo
/// result key against the draft schema `RequestMetaObject` / `ResultMetaObject`
/// shapes. These helpers are additive: they must not consume or rewrite
/// unknown `_meta` keys.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

void main() {
  group('McpRequestMeta keys', () {
    test('reverse-DNS key constants match the draft schema', () {
      expect(McpRequestMeta.keyProtocolVersion,
          equals('io.modelcontextprotocol/protocolVersion'));
      expect(McpRequestMeta.keyClientInfo,
          equals('io.modelcontextprotocol/clientInfo'));
      expect(McpRequestMeta.keyClientCapabilities,
          equals('io.modelcontextprotocol/clientCapabilities'));
      expect(McpRequestMeta.keyLogLevel,
          equals('io.modelcontextprotocol/logLevel'));
      expect(McpRequestMeta.keyServerInfo,
          equals('io.modelcontextprotocol/serverInfo'));
    });
  });

  group('McpRequestMeta.build', () {
    test('emits required keys and optional keys when present', () {
      final meta = McpRequestMeta.build(
        protocolVersion: McpProtocol.v2026_07_28,
        clientCapabilities: {'elicitation': <String, dynamic>{}},
        clientInfo: {'name': 'c', 'version': '1.0.0'},
        logLevel: 'info',
      );
      expect(meta[McpRequestMeta.keyProtocolVersion], '2026-07-28');
      expect(meta[McpRequestMeta.keyClientCapabilities],
          {'elicitation': <String, dynamic>{}});
      expect(meta[McpRequestMeta.keyClientInfo],
          {'name': 'c', 'version': '1.0.0'});
      expect(meta[McpRequestMeta.keyLogLevel], 'info');
    });

    test('omits optional keys when absent; empty caps are preserved', () {
      final meta = McpRequestMeta.build(
        protocolVersion: '2026-07-28',
        clientCapabilities: <String, dynamic>{},
      );
      expect(meta.containsKey(McpRequestMeta.keyClientInfo), isFalse);
      expect(meta.containsKey(McpRequestMeta.keyLogLevel), isFalse);
      // Empty object means "declared, no optional capabilities".
      expect(meta[McpRequestMeta.keyClientCapabilities], <String, dynamic>{});
    });

    test('merges extra first so reserved keys win; input is not mutated', () {
      final extra = {'com.example/trace': 'abc', 'progressToken': 7};
      final meta = McpRequestMeta.build(
        protocolVersion: '2026-07-28',
        clientCapabilities: <String, dynamic>{},
        extra: extra,
      );
      expect(meta['com.example/trace'], 'abc');
      expect(meta['progressToken'], 7);
      expect(meta[McpRequestMeta.keyProtocolVersion], '2026-07-28');
      // Original extra map untouched.
      expect(extra.containsKey(McpRequestMeta.keyProtocolVersion), isFalse);
    });
  });

  group('McpRequestMeta read helpers', () {
    final meta = {
      McpRequestMeta.keyProtocolVersion: '2026-07-28',
      McpRequestMeta.keyClientInfo: {'name': 'c', 'version': '2'},
      McpRequestMeta.keyClientCapabilities: {'sampling': <String, dynamic>{}},
      McpRequestMeta.keyLogLevel: 'debug',
      'unknown/key': 'kept',
    };

    test('reads each typed field', () {
      expect(McpRequestMeta.readProtocolVersion(meta), '2026-07-28');
      expect(McpRequestMeta.readClientInfo(meta),
          {'name': 'c', 'version': '2'});
      expect(McpRequestMeta.readClientCapabilities(meta),
          {'sampling': <String, dynamic>{}});
      expect(McpRequestMeta.readLogLevel(meta), 'debug');
    });

    test('null / wrong-typed meta yields null (no throw)', () {
      expect(McpRequestMeta.readProtocolVersion(null), isNull);
      expect(McpRequestMeta.readProtocolVersion('not-a-map'), isNull);
      expect(McpRequestMeta.readClientCapabilities({}), isNull);
      expect(McpRequestMeta.readClientInfo({}), isNull);
    });

    test('absent client capabilities is null (distinct from empty object)', () {
      expect(McpRequestMeta.readClientCapabilities({}), isNull);
      expect(
          McpRequestMeta.readClientCapabilities(
              {McpRequestMeta.keyClientCapabilities: <String, dynamic>{}}),
          <String, dynamic>{});
    });
  });

  group('McpRequestMeta result serverInfo', () {
    test('buildResult / readServerInfo round-trip', () {
      final resultMeta = McpRequestMeta.buildResult(
        serverInfo: {'name': 's', 'version': '9'},
        extra: {'com.example/req': 'x'},
      );
      expect(resultMeta['com.example/req'], 'x');
      expect(McpRequestMeta.readServerInfo(resultMeta),
          {'name': 's', 'version': '9'});
    });
  });

  group('McpRequestMeta subscriptionId', () {
    test('key constant matches the draft schema', () {
      expect(McpRequestMeta.keySubscriptionId,
          'io.modelcontextprotocol/subscriptionId');
    });

    test('withSubscriptionId stamps _meta on a fresh copy of params without '
        'mutating the input', () {
      final params = {'uri': 'file:///a.txt'};
      final stamped = McpRequestMeta.withSubscriptionId(params, 'sub-1');
      expect(stamped['uri'], 'file:///a.txt');
      expect(stamped['_meta'], {McpRequestMeta.keySubscriptionId: 'sub-1'});
      // The original params map is untouched (no _meta key was added).
      expect(params.containsKey('_meta'), isFalse);
    });

    test('withSubscriptionId merges into an existing _meta object', () {
      final params = {
        'uri': 'file:///a.txt',
        '_meta': {'com.example/other': 1},
      };
      final stamped = McpRequestMeta.withSubscriptionId(params, 'sub-2');
      expect(stamped['_meta'], {
        'com.example/other': 1,
        McpRequestMeta.keySubscriptionId: 'sub-2',
      });
    });

    test('withSubscriptionId accepts null params and non-string ids', () {
      final stamped = McpRequestMeta.withSubscriptionId(null, 7);
      expect(stamped['_meta'], {McpRequestMeta.keySubscriptionId: 7});
    });

    test('readSubscriptionId reads the stamped value, null when absent', () {
      final meta = {McpRequestMeta.keySubscriptionId: 'sub-3'};
      expect(McpRequestMeta.readSubscriptionId(meta), 'sub-3');
      expect(McpRequestMeta.readSubscriptionId(const {}), isNull);
      expect(McpRequestMeta.readSubscriptionId(null), isNull);
      expect(McpRequestMeta.readSubscriptionId('not-a-map'), isNull);
    });
  });
}
