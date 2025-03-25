import 'package:mcp_server/mcp_server.dart';

void main() {
  // Create MCP server instance
  final server = McpServer.createServer(
    name: 'ExampleMCPServer',
    version: '2025.03.25',
  );

  // Create SSE transport for server
  final transport = McpServer.createSseTransport(
    endpoint: '/mcp',
    port: 8080,
  );

  // Connect server to transport
  server.connect(transport);

  McpServer.debug('MCP Server is running on http://localhost:8080/mcp');
}
