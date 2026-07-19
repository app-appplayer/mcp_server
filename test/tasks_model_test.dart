/// Tasks extension (MCP 2026-07-28) — Task model + CreateTaskResult shape.
library;

import 'package:mcp_server/mcp_server.dart';
import 'package:test/test.dart';

void main() {
  group('Tasks model (server)', () {
    test('TaskStatus wire mapping + terminal', () {
      expect(TaskStatus.working.wire, 'working');
      expect(TaskStatus.inputRequired.wire, 'input_required');
      expect(TaskStatus.completed.wire, 'completed');
      expect(TaskStatus.failed.wire, 'failed');
      expect(TaskStatus.cancelled.wire, 'cancelled');
      expect(TaskStatus.fromWire('cancelled'), TaskStatus.cancelled);
      expect(TaskStatus.fromWire('working'), TaskStatus.working);
      expect(TaskStatus.fromWire('input_required'), TaskStatus.inputRequired);
      expect(TaskStatus.fromWire('completed'), TaskStatus.completed);
      expect(TaskStatus.fromWire('failed'), TaskStatus.failed);
      expect(TaskStatus.working.isTerminal, isFalse);
      expect(TaskStatus.inputRequired.isTerminal, isFalse);
      expect(TaskStatus.completed.isTerminal, isTrue);
      expect(TaskStatus.failed.isTerminal, isTrue);
      expect(TaskStatus.cancelled.isTerminal, isTrue);
    });

    test('TaskStatus.fromWire throws ArgumentError for an unknown status',
        () {
      expect(() => TaskStatus.fromWire('bogus'),
          throwsA(isA<ArgumentError>()));
    });

    test('Task.copyWith overrides only the given fields', () {
      const t = Task(
        taskId: 't-4',
        status: TaskStatus.working,
        createdAt: 'a',
        lastUpdatedAt: 'b',
        ttlMs: 1000,
      );
      final updated = t.copyWith(
        status: TaskStatus.completed,
        lastUpdatedAt: 'c',
        result: {'ok': true},
      );
      expect(updated.taskId, 't-4'); // unchanged
      expect(updated.createdAt, 'a'); // unchanged
      expect(updated.status, TaskStatus.completed);
      expect(updated.lastUpdatedAt, 'c');
      expect(updated.result, {'ok': true});
      expect(updated.ttlMs, 1000); // preserved via ?? fallback

      final untouched = t.copyWith();
      expect(untouched.status, TaskStatus.working);
      expect(untouched.lastUpdatedAt, 'b');
    });

    test('Task base + detailed round-trip', () {
      const t = Task(
        taskId: 't-1',
        status: TaskStatus.inputRequired,
        createdAt: '2026-07-28T00:00:00Z',
        lastUpdatedAt: '2026-07-28T00:00:01Z',
        statusMessage: 'awaiting name',
        ttlMs: 60000,
        pollIntervalMs: 500,
        inputRequests: {'ask': {'method': 'elicitation/create'}},
      );
      final base = t.toJson();
      expect(base['taskId'], 't-1');
      expect(base['status'], 'input_required');
      expect(base['ttlMs'], 60000); // always present per schema
      expect(base.containsKey('inputRequests'), isFalse); // base omits detail

      final detailed = t.toDetailedJson();
      expect(detailed['inputRequests'], {'ask': {'method': 'elicitation/create'}});

      final back = Task.fromJson(detailed);
      expect(back.status, TaskStatus.inputRequired);
      expect(back.statusMessage, 'awaiting name');
      expect(back.pollIntervalMs, 500);
    });

    test('unlimited ttl serializes as null', () {
      const t = Task(
        taskId: 't-2',
        status: TaskStatus.working,
        createdAt: 'a',
        lastUpdatedAt: 'b',
        ttlMs: null,
      );
      expect(t.toJson()['ttlMs'], isNull);
      expect(t.toJson().containsKey('ttlMs'), isTrue);
    });

    test('CreateTaskResult stamps resultType:task (flat Result & Task)', () {
      const t = Task(
        taskId: 't-3',
        status: TaskStatus.working,
        createdAt: 'a',
        lastUpdatedAt: 'b',
        ttlMs: null,
      );
      final r = t.toCreateTaskResult(meta: {'io.example/x': 1});
      expect(r['resultType'], McpResultType.task);
      expect(r['taskId'], 't-3');
      expect(r['status'], 'working');
      expect(r['_meta'], {'io.example/x': 1});
    });

    test('Task.fromJson parses result and error detail fields', () {
      final completed = Task.fromJson({
        'taskId': 't-5',
        'status': 'completed',
        'createdAt': 'a',
        'lastUpdatedAt': 'b',
        'ttlMs': null,
        'result': {'content': []},
      });
      expect(completed.status, TaskStatus.completed);
      expect(completed.result, {'content': []});
      expect(completed.error, isNull);

      final failed = Task.fromJson({
        'taskId': 't-6',
        'status': 'failed',
        'createdAt': 'a',
        'lastUpdatedAt': 'b',
        'ttlMs': null,
        'error': {'code': -32000, 'message': 'boom'},
      });
      expect(failed.status, TaskStatus.failed);
      expect(failed.error, {'code': -32000, 'message': 'boom'});
      expect(failed.result, isNull);
      // detailed JSON round-trips the error payload too.
      expect(failed.toDetailedJson()['error'], {'code': -32000, 'message': 'boom'});
    });

    test('extension id constant', () {
      expect(tasksExtensionId, 'io.modelcontextprotocol/tasks');
    });
  });
}
