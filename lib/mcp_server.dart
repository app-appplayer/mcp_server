import 'dart:io';

import 'src/server/server.dart';
import 'src/transport/transport.dart';

export 'src/models/models.dart';
export 'src/server/server.dart';
export 'src/transport/transport.dart';

/// Main plugin class for MCP Server implementation
class McpServer {

  /// Create a new MCP server with the specified configuration
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

  /// Create a stdio transport for the server
  static StdioServerTransport createStdioTransport() {
    return StdioServerTransport();
  }

  /// Create an SSE transport for the server with configurable ports
  static SseServerTransport createSseTransport({
    required String endpoint,
    String? messagesEndpoint,
    int port = 8080,
    List<int>? fallbackPorts,
  }) {
    return SseServerTransport(
      endpoint: endpoint,
      messagesEndpoint: messagesEndpoint ?? '/messages',
      port: port,
      fallbackPorts: fallbackPorts,
    );
  }

  /// Log message to stderr for debugging
  static void debug(String message) {
    stderr.writeln('[MCP Debug] $message');
  }
}
