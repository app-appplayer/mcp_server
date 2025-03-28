import 'package:mcp_server/logger.dart';
import 'package:mcp_server/mcp_server.dart';

void main() {
  // Create MCP server instance
  final server = McpServer.createServer(
    name: 'ExampleMCPServer',
    version: '1.0.0',
  );

  // Create SSE transport for server
  final transport = McpServer.createSseTransport(
    endpoint: '/mcp',
    port: 8080,
  );

  // Connect server to transport
  server.connect(transport);

  log.debug('MCP Server is running on http://localhost:8080/mcp');
}
