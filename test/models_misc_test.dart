/// Pure-logic coverage for the remaining model classes in
/// `lib/src/models/models.dart` — `Root`, `ServerHealth`, `CachedResource`,
/// `PendingOperation`, `ClientSession`, `ProgressNotification`,
/// `PromptMessage`, `CancellationToken`, `CancelledException`, and the
/// `ErrorCode` constant table.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

void main() {
  group('Root', () {
    test('toJson without description', () {
      final root = Root(uri: 'file:///project', name: 'project');
      expect(root.toJson(), {'uri': 'file:///project', 'name': 'project'});
    });

    test('toJson with description', () {
      final root = Root(
        uri: 'file:///project',
        name: 'project',
        description: 'the workspace root',
      );
      expect(root.toJson(), {
        'uri': 'file:///project',
        'name': 'project',
        'description': 'the workspace root',
      });
    });
  });

  group('ServerHealth', () {
    test('toJson without optional fields', () {
      final health = ServerHealth(
        isRunning: true,
        connectedSessions: 2,
        registeredTools: 3,
        registeredResources: 1,
        registeredPrompts: 0,
        startTime: DateTime.utc(2026, 1, 1),
        uptime: const Duration(seconds: 90),
        metrics: {'requests': 10},
      );
      final json = health.toJson();
      expect(json['status'], 'healthy');
      expect(json.containsKey('version'), isFalse);
      expect(json['isRunning'], isTrue);
      expect(json['connectedSessions'], 2);
      expect(json['registeredTools'], 3);
      expect(json['registeredResources'], 1);
      expect(json['registeredPrompts'], 0);
      expect(json['startTime'], DateTime.utc(2026, 1, 1).toIso8601String());
      expect(json['uptimeSeconds'], 90);
      expect(json['metrics'], {'requests': 10});
      expect(json.containsKey('capabilities'), isFalse);
    });

    test('toJson with version, custom status, and capabilities', () {
      final health = ServerHealth(
        status: 'degraded',
        version: '2.0.0',
        isRunning: false,
        connectedSessions: 0,
        registeredTools: 0,
        registeredResources: 0,
        registeredPrompts: 0,
        startTime: DateTime.utc(2026, 1, 1),
        uptime: Duration.zero,
        metrics: const {},
        capabilities: {'tools': true},
      );
      final json = health.toJson();
      expect(json['status'], 'degraded');
      expect(json['version'], '2.0.0');
      expect(json['capabilities'], {'tools': true});
    });
  });

  group('CachedResource', () {
    test('isExpired is false before maxAge elapses', () {
      final resource = CachedResource(
        uri: 'file:///a.txt',
        content: ReadResourceResult(contents: const []),
        cachedAt: DateTime.now(),
        maxAge: const Duration(hours: 1),
      );
      expect(resource.isExpired, isFalse);
    });

    test('isExpired is true once maxAge has elapsed', () {
      final resource = CachedResource(
        uri: 'file:///a.txt',
        content: ReadResourceResult(contents: const []),
        cachedAt: DateTime.now().subtract(const Duration(hours: 2)),
        maxAge: const Duration(hours: 1),
      );
      expect(resource.isExpired, isTrue);
    });
  });

  group('PendingOperation', () {
    test('toJson without requestId, defaults isCancelled false', () {
      final op = PendingOperation(id: 'op-1', sessionId: 's-1', type: 'tool');
      final json = op.toJson();
      expect(json['id'], 'op-1');
      expect(json['sessionId'], 's-1');
      expect(json['type'], 'tool');
      expect(json['isCancelled'], isFalse);
      expect(json.containsKey('requestId'), isFalse);
      expect(json['createdAt'], isA<String>());
    });

    test('toJson with requestId and after cancellation', () {
      final op = PendingOperation(
        id: 'op-2',
        sessionId: 's-1',
        type: 'tool',
        requestId: 'req-9',
      );
      op.isCancelled = true;
      final json = op.toJson();
      expect(json['requestId'], 'req-9');
      expect(json['isCancelled'], isTrue);
    });
  });

  group('ErrorCode', () {
    test('constants match the standard JSON-RPC and MCP error codes', () {
      expect(ErrorCode.parseError, -32700);
      expect(ErrorCode.invalidRequest, -32600);
      expect(ErrorCode.methodNotFound, -32601);
      expect(ErrorCode.invalidParams, -32602);
      expect(ErrorCode.internalError, -32603);
      expect(ErrorCode.resourceNotFound, -32100);
      expect(ErrorCode.toolNotFound, -32101);
      expect(ErrorCode.promptNotFound, -32102);
      expect(ErrorCode.incompatibleVersion, -32103);
      expect(ErrorCode.unauthorized, -32104);
      expect(ErrorCode.operationCancelled, -32105);
      expect(ErrorCode.rateLimited, -32106);
    });
  });

  group('ClientSession', () {
    test('constructor defaults and toJson shape', () {
      final connectedAt = DateTime.utc(2026, 1, 1);
      final session = ClientSession(id: 's-1', connectedAt: connectedAt);
      expect(session.isInitialized, isFalse);
      expect(session.isStateless, isFalse);
      expect(session.negotiatedProtocolVersion, isNull);
      expect(session.roots, isEmpty);

      final json = session.toJson();
      expect(json['id'], 's-1');
      expect(json['connectedAt'], connectedAt.toIso8601String());
      expect(json['metadata'], <String, dynamic>{});
      expect(json['isInitialized'], isFalse);
      expect(json['negotiatedProtocolVersion'], isNull);
      expect(json['capabilities'], isNull);
      expect(json['roots'], isEmpty);
    });

    test('toJson reflects mutated fields', () {
      final session = ClientSession(
        id: 's-2',
        connectedAt: DateTime.utc(2026, 1, 1),
        metadata: const {'client': 'test'},
      );
      session.isInitialized = true;
      session.negotiatedProtocolVersion = '2025-11-25';
      session.capabilities = {'tools': <String, dynamic>{}};
      session.roots = [
        {'uri': 'file:///a', 'name': 'a'}
      ];

      final json = session.toJson();
      expect(json['metadata'], {'client': 'test'});
      expect(json['isInitialized'], isTrue);
      expect(json['negotiatedProtocolVersion'], '2025-11-25');
      expect(json['capabilities'], {'tools': <String, dynamic>{}});
      expect(json['roots'], [
        {'uri': 'file:///a', 'name': 'a'}
      ]);
    });
  });

  group('ProgressNotification', () {
    test('toJson without total', () {
      const notif = ProgressNotification(progressToken: 'tok-1', progress: 0.5);
      expect(notif.toJson(), {'progressToken': 'tok-1', 'progress': 0.5});
    });

    test('toJson with total', () {
      const notif = ProgressNotification(
        progressToken: 'tok-1',
        progress: 3,
        total: 10,
      );
      expect(notif.toJson(), {
        'progressToken': 'tok-1',
        'progress': 3.0,
        'total': 10.0,
      });
    });
  });

  group('PromptMessage', () {
    test('toJson uses the enum name for role', () {
      const message = PromptMessage(
        role: PromptMessageRole.assistant,
        content: TextContent(text: 'hi'),
      );
      expect(message.toJson(), {
        'role': 'assistant',
        'content': {'type': 'text', 'text': 'hi'},
      });
    });

    test('every PromptMessageRole value serializes to its name', () {
      expect(PromptMessageRole.user.name, 'user');
      expect(PromptMessageRole.assistant.name, 'assistant');
      expect(PromptMessageRole.system.name, 'system');
    });
  });

  group('CancellationToken', () {
    test('starts uncancelled', () {
      final token = CancellationToken();
      expect(token.isCancelled, isFalse);
      expect(() => token.throwIfCancelled(), returnsNormally);
    });

    test('cancel() flips isCancelled and notifies registered callbacks', () {
      final token = CancellationToken();
      var calls = 0;
      token.onCancel(() => calls++);
      token.onCancel(() => calls++);
      token.cancel();
      expect(token.isCancelled, isTrue);
      expect(calls, 2);
    });

    test('cancel() is idempotent — callbacks fire only once', () {
      final token = CancellationToken();
      var calls = 0;
      token.onCancel(() => calls++);
      token.cancel();
      token.cancel();
      expect(calls, 1);
    });

    test('onCancel invokes the callback immediately if already cancelled',
        () {
      final token = CancellationToken()..cancel();
      var called = false;
      token.onCancel(() => called = true);
      expect(called, isTrue);
    });

    test('removeCallback prevents a registered callback from firing', () {
      final token = CancellationToken();
      var calls = 0;
      void cb() => calls++;
      token.onCancel(cb);
      token.removeCallback(cb);
      token.cancel();
      expect(calls, 0);
    });

    test('throwIfCancelled throws CancelledException once cancelled', () {
      final token = CancellationToken()..cancel();
      expect(() => token.throwIfCancelled(),
          throwsA(isA<CancelledException>()));
    });
  });

  group('CancelledException', () {
    test('default message', () {
      final ex = CancelledException();
      expect(ex.message, 'Operation cancelled');
      expect(ex.toString(), 'CancelledException: Operation cancelled');
    });

    test('custom message', () {
      final ex = CancelledException('user aborted');
      expect(ex.message, 'user aborted');
      expect(ex.toString(), 'CancelledException: user aborted');
    });
  });
}
