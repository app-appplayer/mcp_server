import 'dart:async';
import 'dart:io';

import 'package:mcp_server/mcp_server.dart';
import 'package:test/test.dart';

/// `SseServerTransport.close()` with sessions still open (issue #5): it must
/// not throw, must release the port, and must complete `onClose` only once
/// the port is released.
void main() {
  Future<int> freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Future<bool> portOpen(int port) => Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 1),
      )
      .then((s) {
        s.destroy();
        return true;
      })
      .catchError((_) => false);

  /// Starts an SSE server with one client connected and returns what the
  /// test needs to close it.
  Future<
    ({
      Server server,
      ServerTransport transport,
      int port,
      HttpClient client,
      StreamSubscription<List<int>> reader,
    })
  >
  serverWithSession() async {
    final port = await freePort();
    final server = McpServer.createServer(
      McpServerConfig(
        name: 'close-test',
        version: '1.0.0',
        capabilities: ServerCapabilities(tools: ToolsCapability()),
      ),
    );
    final transport = await McpServer.createTransport(
      TransportConfig.sse(
        host: '127.0.0.1',
        port: port,
        endpoint: '/sse',
        messagesEndpoint: '/message',
      ),
    ).fold((t) => t, (e) => throw e);
    server.connect(transport);

    final client = HttpClient();
    final response =
        await (await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/sse'),
        )).close();
    final reader = response.listen((_) {});
    // Wait for the session to be registered (endpoint event sent).
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return (
      server: server,
      transport: transport,
      port: port,
      client: client,
      reader: reader,
    );
  }

  Future<List<Object>> disconnectAndWait(Server server, ServerTransport t) {
    final errors = <Object>[];
    final done = Completer<List<Object>>();
    runZonedGuarded(
      () async {
        server.disconnect();
        await t.onClose.timeout(const Duration(seconds: 10));
        done.complete(errors);
      },
      (e, _) {
        errors.add(e);
        if (!done.isCompleted) done.complete(errors);
      },
    );
    return done.future;
  }

  test(
    'an open session: no error, port released when onClose completes',
    () async {
      final s = await serverWithSession();
      expect(await portOpen(s.port), isTrue);

      final errors = await disconnectAndWait(s.server, s.transport);

      expect(errors, isEmpty);
      expect(await portOpen(s.port), isFalse);
      await s.reader.cancel().catchError((_) {});
      s.client.close(force: true);
    },
  );

  test(
    'a session whose write is still flushing: no error, port released',
    () async {
      final s = await serverWithSession();
      // The client stops reading, so the server's writes back up and a flush
      // is in flight when close() runs.
      s.reader.pause();
      final big = 'x' * (1 << 20);
      for (var i = 0; i < 8; i++) {
        s.transport.send({
          'jsonrpc': '2.0',
          'method': 'notifications/message',
          'params': {'data': big},
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final errors = await disconnectAndWait(s.server, s.transport);

      expect(errors, isEmpty);
      expect(await portOpen(s.port), isFalse);
      await s.reader.cancel().catchError((_) {});
      s.client.close(force: true);
    },
  );

  test('closing twice is harmless', () async {
    final s = await serverWithSession();
    final errors = await disconnectAndWait(s.server, s.transport);
    expect(errors, isEmpty);
    await (s.transport as dynamic).close();
    expect(await portOpen(s.port), isFalse);
    await s.reader.cancel().catchError((_) {});
    s.client.close(force: true);
  });
}
