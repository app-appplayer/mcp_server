/// Tasks extension (MCP 2026-07-28) — server task store + `tasks/get` /
/// `tasks/update` / `tasks/cancel` RPC lifecycle, over the real stateless
/// wire with the in-tree client. Gated: dormant unless the tasks extension is
/// advertised in `capabilities.extensions`.
@TestOn('vm')
library;

import 'dart:async';
import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';
import 'package:mcp_client/mcp_client.dart' as mc;

Server _tasksServer(StreamableHttpServerTransport t) {
  final server = Server(
    name: 'tasks-fixture',
    version: '1.0.0',
    capabilities: const ServerCapabilities(
      tools: ToolsCapability(),
      extensions: {tasksExtensionId: {}},
    ),
  );
  server.connect(t);
  return server;
}

void main() {
  group('Tasks lifecycle (stateless RPC)', () {
    test('create → get(working) → complete → get(completed); cancel',
        () async {
      const port = 8590;
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: port,
          isJsonResponseEnabled: true,
          enableStateless: true,
        ),
      );
      final server = _tasksServer(transport);
      await transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final client = mc.Client(name: 'c', version: '2.0.0');
      final tx = await mc.StreamableHttpClientTransport.create(
        baseUrl: 'http://localhost:$port/mcp',
      );
      try {
        await client.connect(tx, statelessMode: true);

        // Server app elects to run something as a task.
        final created = server.createTask(
            statusMessage: 'crunching', ttlMs: 60000, pollIntervalMs: 500);
        expect(created.status, TaskStatus.working);

        // Client discovered the tasks extension.
        await client.discover();
        expect(client.supportsTasks, isTrue);

        // tasks/get → working.
        final got = await client.getTask(created.taskId);
        expect(got.taskId, created.taskId);
        expect(got.status, mc.TaskStatus.working);
        expect(got.pollIntervalMs, 500);

        // App completes it; client re-polls → completed + result.
        server.completeTask(created.taskId, {
          'content': [
            {'type': 'text', 'text': 'done'}
          ],
        });
        final done = await client.getTask(created.taskId);
        expect(done.status, mc.TaskStatus.completed);
        expect(done.isTerminal, isTrue);
        expect(done.result!['content'], isA<List>());

        // A second task cancelled by the client.
        final t2 = server.createTask();
        await client.cancelTask(t2.taskId);
        expect(server.task(t2.taskId)!.status, TaskStatus.cancelled);
      } finally {
        client.disconnect();
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });

    test('tasks/get missing → -32602 (stateless)', () async {
      const port = 8591;
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: port,
          isJsonResponseEnabled: true,
          enableStateless: true,
        ),
      );
      final server = _tasksServer(transport);
      await transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final client = mc.Client(name: 'c', version: '2.0.0');
      final tx = await mc.StreamableHttpClientTransport.create(
          baseUrl: 'http://localhost:$port/mcp');
      try {
        await client.connect(tx, statelessMode: true);
        mc.McpError? err;
        try {
          await client.getTask('does-not-exist');
        } on mc.McpError catch (e) {
          err = e;
        }
        expect(err, isNotNull);
        expect(err!.code, -32602);
      } finally {
        client.disconnect();
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });

    test('tasks are dormant when the extension is not advertised', () async {
      const port = 8592;
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: port,
          isJsonResponseEnabled: true,
          enableStateless: true,
        ),
      );
      // No tasks extension in capabilities.
      final server = Server(
        name: 'no-tasks',
        version: '1.0.0',
        capabilities: const ServerCapabilities(tools: ToolsCapability()),
      );
      server.connect(transport);
      await transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final client = mc.Client(name: 'c', version: '2.0.0');
      final tx = await mc.StreamableHttpClientTransport.create(
          baseUrl: 'http://localhost:$port/mcp');
      try {
        await client.connect(tx, statelessMode: true);
        expect(client.supportsTasks, isFalse);
        mc.McpError? err;
        try {
          await client.getTask('x');
        } on mc.McpError catch (e) {
          err = e;
        }
        expect(err, isNotNull); // method-not-found — dormant
      } finally {
        client.disconnect();
        server.dispose();
        transport.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });
  });
}
