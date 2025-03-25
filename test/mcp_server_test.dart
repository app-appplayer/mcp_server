import 'package:mcp_server/logger.dart';
import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

void main() {
  group('McpServer', () {
    test('createServer returns a Server instance', () {
      final server = McpServer.createServer(
        name: 'TestServer',
        version: '1.0.0',
      );

      expect(server, isNotNull);
      expect(server.name, equals('TestServer'));
      expect(server.version, equals('1.0.0'));
    });

    test('createStdioTransport returns StdioServerTransport', () {
      final transport = McpServer.createStdioTransport();
      expect(transport, isA<StdioServerTransport>());
    });

    test('createSseTransport returns SseServerTransport with defaults', () {
      final transport = McpServer.createSseTransport(endpoint: '/test');

      expect(transport, isA<SseServerTransport>());
      expect(transport.endpoint, equals('/test'));
      expect(transport.messagesEndpoint, equals('/messages'));
      expect(transport.port, equals(8080));
    });

    test('debug does not throw', () {
      expect(() => Logger.debug('Debug test message'), returnsNormally);
    });
  });
}