import 'package:mcp_server/mcp_server.dart';

void main() {
  // MCP 서버 인스턴스 생성
  final server = McpServer.createServer(
    name: 'ExampleMCPServer',
    version: '2025.03.25',
  );

  // SSE 방식으로 서버 열기
  final transport = McpServer.createSseTransport(
    endpoint: '/mcp',
    port: 8080,
  );

  // Connect server to transport
  server.connect(transport);

  McpServer.debug('MCP Server is running on http://localhost:8080/mcp');
}
