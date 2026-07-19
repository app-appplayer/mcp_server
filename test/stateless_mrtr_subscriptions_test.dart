/// 2026-07-28 stateless core R2 (SEP-2577) — Multi-Round-Trip (`InputRequired
/// Result`) + `subscriptions/listen`, plus the B6 error-code gate — proven on
/// the real Streamable HTTP wire with the in-tree `mcp_client` (pubspec_over
/// rides), AND that the legacy 2025-11-25 handshake path is untouched.
///
/// Everything here is BUILD-DORMANT: it only runs against a server with
/// `enableStateless: true`. With the flag OFF (the default) none of this is
/// reachable — see `stateless_coexistence_test.dart` for the gate.
@TestOn('vm')
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';
import 'package:mcp_client/mcp_client.dart' as mc;

Server _buildServer() {
  final server = Server(
    name: 'mrtr-fixture',
    version: '1.0.0',
    capabilities: ServerCapabilities.simple(
      tools: true,
      toolsListChanged: true,
      resources: true,
      resourcesListChanged: true,
    ),
  );

  // MRTR tool: first round returns `input_required` (needs an elicitation);
  // second round reads the client's elicit response and produces the terminal
  // greeting, echoing the opaque requestState it previously issued.
  server.addTool(
    name: 'greet',
    description: 'Greets the user after eliciting their name',
    inputSchema: {'type': 'object', 'properties': {}},
    handler: (args) async {
      final responses = McpMrtr.readInputResponses(args);
      if (responses == null) {
        // Round 1: ask the client to elicit the name; stash opaque state.
        return InputRequiredResult(
          inputRequests: {
            'ask-name': InputRequiredResult.elicitRequest(
              message: 'What is your name?',
              requestedSchema: {
                'type': 'object',
                'properties': {
                  'name': {'type': 'string'},
                },
                'required': ['name'],
              },
            ),
          },
          requestState: 'awaiting-name-v1',
        );
      }
      // Round 2: the client fulfilled the elicitation and re-issued.
      final elicit = responses['ask-name'] as Map;
      final content = elicit['content'] as Map;
      final name = content['name'];
      final state = McpMrtr.readRequestState(args);
      return CallToolResult(
        content: [TextContent(text: 'Hello, $name! [$state]')],
      );
    },
  );

  return server;
}

void main() {
  group('2026-07-28 stateless R2 — MRTR + subscriptions/listen', () {
    test(
        'MRTR round-trip: tools/call → input_required → client elicits → '
        're-issue → terminal result', () async {
      const port = 8581;
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: port,
          isJsonResponseEnabled: true,
          enableStateless: true,
        ),
      );
      final server = _buildServer();
      server.connect(transport);
      await transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      try {
        final tx = await mc.StreamableHttpClientTransport.create(
          baseUrl: 'http://localhost:$port/mcp',
        );
        final client = mc.Client(name: 'mrtr-client', version: '2.0.0');
        await client.connect(tx, statelessMode: true);
        expect(client.isStateless, isTrue);

        // The client fulfills the server's elicitation request locally.
        var elicitCalls = 0;
        client.onElicitationRequest((params) async {
          elicitCalls++;
          expect(params['message'], 'What is your name?');
          return {
            'action': 'accept',
            'content': {'name': 'Ada'},
          };
        });

        // A single callTool drives the full multi-round-trip transparently.
        final result = await client.callTool('greet', {});
        expect(elicitCalls, 1, reason: 'exactly one elicitation round-trip');
        expect((result.content.first as mc.TextContent).text,
            'Hello, Ada! [awaiting-name-v1]');

        client.disconnect();
      } finally {
        transport.close();
      }
    });

    test(
        'MRTR does not fire on a normal (complete) tool call — resultType '
        'complete is stamped and passes straight through', () async {
      const port = 8582;
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: port,
          isJsonResponseEnabled: true,
          enableStateless: true,
        ),
      );
      final server = Server(
        name: 'plain',
        version: '1.0.0',
        capabilities: ServerCapabilities.simple(tools: true),
      )..addTool(
          name: 'echo',
          description: 'echo',
          inputSchema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
            },
          },
          handler: (args) async =>
              CallToolResult(content: [TextContent(text: '${args['text']}')]),
        );
      server.connect(transport);
      await transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      try {
        final tx = await mc.StreamableHttpClientTransport.create(
          baseUrl: 'http://localhost:$port/mcp',
        );
        final client = mc.Client(name: 'c', version: '2.0.0');
        await client.connect(tx, statelessMode: true);

        // No elicitation handler registered — if MRTR wrongly triggered it
        // would throw. A plain complete result must resolve directly.
        final result = await client.callTool('echo', {'text': 'ping'});
        expect((result.content.first as mc.TextContent).text, 'ping');

        client.disconnect();
      } finally {
        transport.close();
      }
    });

    test(
        'subscriptions/listen: acknowledged honored subset, filtered delivery, '
        'subscriptionId stamping, cancellation closes the stream', () async {
      const port = 8583;
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: port,
          isJsonResponseEnabled: true,
          enableStateless: true,
        ),
      );
      final server = _buildServer();
      server.connect(transport);
      await transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      try {
        final tx = await mc.StreamableHttpClientTransport.create(
          baseUrl: 'http://localhost:$port/mcp',
        );
        final client = mc.Client(name: 'sub-client', version: '2.0.0');
        await client.connect(tx, statelessMode: true);

        final received = <mc.SubscriptionNotification>[];
        final sub = await client.listen(const mc.SubscriptionFilter(
          resourcesListChanged: true,
          resourceSubscriptions: ['file:///watched'],
          // Deliberately NOT requesting toolsListChanged.
        ));
        final streamDone = Completer<void>();
        sub.notifications.listen(received.add,
            onDone: () => streamDone.complete());

        // The acknowledged notification (first message) reports the honored
        // subset and MUST arrive before any stream notification.
        final honored = await sub.acknowledged
            .timeout(const Duration(seconds: 5));
        expect(honored.resourcesListChanged, isTrue);
        expect(honored.resourceSubscriptions, contains('file:///watched'));
        expect(honored.toolsListChanged, isFalse);

        // Trigger a subscribed resource update AND an unrequested tools change.
        server.notifyResourceUpdated('file:///watched');
        server.addTool(
          name: 'late',
          description: 'added after listen — triggers tools/list_changed',
          inputSchema: {'type': 'object', 'properties': {}},
          handler: (args) async => CallToolResult(content: const []),
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));

        // Only the opted-in resources/updated arrived — the tools/list_changed
        // was filtered out (server MUST NOT send unrequested types).
        expect(received.map((n) => n.method),
            everyElement('notifications/resources/updated'));
        expect(received, isNotEmpty);
        final n = received.first;
        expect((n.params['uri']), 'file:///watched');
        // Every stream notification is stamped with the subscriptionId.
        expect(
          mc.McpRequestMeta.readSubscriptionId(n.params['_meta']),
          sub.subscriptionId,
        );

        // Cancellation closes the stream (terminal SubscriptionsListenResult).
        sub.cancel();
        await streamDone.future.timeout(const Duration(seconds: 5));

        client.disconnect();
      } finally {
        transport.close();
      }
    });

    test('B6: resource-not-found emits -32602 on the stateless path only',
        () async {
      const port = 8584;
      final transport = StreamableHttpServerTransport(
        config: const StreamableHttpServerConfig(
          port: port,
          isJsonResponseEnabled: true,
          enableStateless: true,
        ),
      );
      final server = Server(
        name: 'res',
        version: '1.0.0',
        capabilities: ServerCapabilities.simple(resources: true),
      );
      server.connect(transport);
      await transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      try {
        // Stateless path → -32602 (INVALID_PARAMS, per draft schema).
        final statelessTx = await mc.StreamableHttpClientTransport.create(
          baseUrl: 'http://localhost:$port/mcp',
        );
        final stateless = mc.Client(name: 'c', version: '2.0.0');
        await stateless.connect(statelessTx, statelessMode: true);
        mc.McpError? statelessErr;
        try {
          await stateless.readResource('file:///missing');
        } on mc.McpError catch (e) {
          statelessErr = e;
        }
        expect(statelessErr, isNotNull);
        expect(statelessErr!.code, -32602);
        stateless.disconnect();

        // Legacy handshake path → prior -32001 (unchanged).
        final legacyTx = await mc.StreamableHttpClientTransport.create(
          baseUrl: 'http://localhost:$port/mcp',
        );
        final legacy = mc.Client(name: 'legacy', version: '1.0.0');
        await legacy.connect(legacyTx);
        mc.McpError? legacyErr;
        try {
          await legacy.readResource('file:///missing');
        } on mc.McpError catch (e) {
          legacyErr = e;
        }
        expect(legacyErr, isNotNull);
        // Legacy path keeps its prior emitted code (`ErrorCode.resourceNotFound`
        // = -32100 in this package) — NOT the gated -32602.
        expect(legacyErr!.code, -32100);
        legacy.disconnect();
      } finally {
        transport.close();
      }
    });
  });
}
