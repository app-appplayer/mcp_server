import 'dart:async';
import 'package:mcp_server/mcp_server.dart';

/// Simple working example that demonstrates the correct API usage
Future<void> main() async {
  final logger = Logger('simple_example');
  logger.info('Starting simple MCP server example');

  // Create server with basic capabilities
  final server = Server(
    name: 'Simple MCP Server',
    version: '1.0.0',
    capabilities: const ServerCapabilities(
      tools: true,
      resources: true,
      prompts: true,
    ),
  );

  // Add a simple tool
  server.addTool(
    name: 'echo',
    description: 'Echo back the input message',
    inputSchema: {
      'type': 'object',
      'properties': {
        'message': {
          'type': 'string',
          'description': 'The message to echo back',
        },
      },
      'required': ['message'],
    },
    handler: (arguments) async {
      final message = arguments['message'] as String;
      return CallToolResult(
        content: [TextContent(text: 'Echo: $message')],
      );
    },
  );

  // Add a simple resource
  server.addResource(
    uri: 'example://greeting',
    name: 'Greeting Resource',
    description: 'A simple greeting resource',
    mimeType: 'text/plain',
    handler: (uri, params) async {
      return ReadResourceResult(
        contents: [
          ResourceContentInfo(
            uri: uri,
            mimeType: 'text/plain',
            text: 'Hello from the resource!',
          ),
        ],
      );
    },
  );

  // Add a simple prompt
  server.addPrompt(
    name: 'greeting_prompt',
    description: 'Generate a greeting message',
    arguments: [
      PromptArgument(
        name: 'name',
        description: 'Name of the person to greet',
        required: true,
      ),
    ],
    handler: (arguments) async {
      final name = arguments['name'] as String;
      return GetPromptResult(
        description: 'A personalized greeting',
        messages: [
          Message(
            role: 'assistant',
            content: TextContent(text: 'Hello, $name! How are you today?'),
          ),
        ],
      );
    },
  );

  // Create STDIO transport
  final transportResult = McpServer.createStdioTransport();
  final transport = transportResult.get();

  // Connect and start server
  server.connect(transport);
  
  logger.info('Server started and connected to STDIO transport');
  logger.info('Server is ready to receive MCP requests');

  // Keep the server running
  await transport.onClose;
  logger.info('Server shutdown complete');
}