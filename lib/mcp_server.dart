import 'dart:io';

import 'src/server/server.dart';
import 'src/transport/transport.dart';

export 'src/models/models.dart';
export 'src/server/server.dart';
export 'src/transport/transport.dart';
export 'logger.dart';

typedef MCPServer = McpServer;

/// Factory class for creating MCP servers and transports
class McpServer {
  /// Create a new MCP server
  static Server createServer({
    required String name,
    required String version,
    ServerCapabilities? capabilities,
  }) {
    return Server(
      name: name,
      version: version,
      capabilities: capabilities ?? const ServerCapabilities(),
    );
  }

  /// Create a stdio transport
  static StdioServerTransport createStdioTransport() {
    return StdioServerTransport();
  }

  /// Create an SSE transport
  static SseServerTransport createSseTransport({
    required String endpoint,
    String? messagesEndpoint,
    int port = 8080,
    List<int>? fallbackPorts,
    String? authToken,
    Future<bool> Function(HttpRequest)? onSseRequestValidator,
  }) {
    return SseServerTransport(
      endpoint: endpoint,
      messagesEndpoint: messagesEndpoint ?? '/messages',
      port: port,
      fallbackPorts: fallbackPorts,
      authToken: authToken,
      onSseRequestValidator: onSseRequestValidator,
    );
  }
}
