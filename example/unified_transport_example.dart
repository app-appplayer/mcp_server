import 'dart:io';
import 'package:mcp_server/mcp_server.dart';

/// Example demonstrating unified transport configurations
void main() async {
  final logger = Logger('unified_transport_example');
  logger.info('🚀 Starting Unified Transport Examples');

  // Example 1: Simple STDIO server
  await exampleStdioServer(logger);

  // Example 2: SSE server with authentication
  await exampleSseServerWithAuth(logger);

  // Example 3: Streamable HTTP server (SSE mode)
  await exampleStreamableHttpSseServer(logger);

  // Example 4: Streamable HTTP server (JSON mode)
  await exampleStreamableHttpJsonServer(logger);

  // Example 5: Production configuration example
  await exampleProductionServer(logger);

  logger.info('✅ All examples completed');
}

/// Example 1: Basic STDIO server
Future<void> exampleStdioServer(Logger logger) async {
  logger.info('\n=== Example 1: STDIO Server ===');

  final serverResult = await McpServer.createAndStart(
    config: McpServer.simpleConfig(
      name: 'STDIO MCP Server',
      version: '1.0.0',
      enableDebugLogging: true,
    ),
    transportConfig: TransportConfig.stdio(),
  );

  await serverResult.fold(
    (server) async {
      logger.info('STDIO server started successfully');
      
      // Add a simple tool
      server.addTool(
        name: 'echo',
        description: 'Echo back the input',
        inputSchema: {
          'type': 'object',
          'properties': {
            'message': {'type': 'string'}
          },
        },
        handler: (args) async {
          final message = args['message'] as String? ?? 'Hello';
          return CallToolResult(
            content: [TextContent(text: 'Echo: $message')],
          );
        },
      );

      logger.info('Server ready - would normally run indefinitely');
      // In real usage: await server.onClose;
      
      server.dispose();
    },
    (error) {
      logger.severe('Failed to start STDIO server: $error');
    },
  );
}

/// Example 2: SSE server with authentication
Future<void> exampleSseServerWithAuth(Logger logger) async {
  logger.info('\n=== Example 2: SSE Server with Authentication ===');

  final serverResult = await McpServer.createAndStart(
    config: McpServer.simpleConfig(
      name: 'SSE MCP Server',
      version: '1.0.0',
    ),
    transportConfig: TransportConfig.sse(
      host: 'localhost',
      port: 8080,
      endpoint: '/sse',
      messagesEndpoint: '/message',
      authToken: 'secure-token-123',
      fallbackPorts: [8081, 8082],
    ),
  );

  await serverResult.fold(
    (server) async {
      logger.info('SSE server started on http://localhost:8080/sse');
      
      // Add tools and resources
      _addExampleTools(server);
      _addExampleResources(server);

      logger.info('SSE server ready with ${server.getTools().length} tools');
      
      // Simulate some uptime
      await Future.delayed(const Duration(seconds: 1));
      
      server.dispose();
    },
    (error) {
      logger.severe('Failed to start SSE server: $error');
    },
  );
}

/// Example 3: Streamable HTTP server (SSE mode)
Future<void> exampleStreamableHttpSseServer(Logger logger) async {
  logger.info('\n=== Example 3: Streamable HTTP Server (SSE Mode) ===');

  final serverResult = await McpServer.createAndStart(
    config: McpServer.productionConfig(
      name: 'StreamableHTTP SSE Server',
      version: '1.0.0',
    ),
    transportConfig: TransportConfig.streamableHttp(
      host: 'localhost',
      port: 8081,
      endpoint: '/mcp',
      isJsonResponseEnabled: false, // SSE streaming mode (default)
      fallbackPorts: [8082, 8083],
    ),
  );

  await serverResult.fold(
    (server) async {
      logger.info('StreamableHTTP server started on http://localhost:8081/mcp');
      logger.info('Response mode: SSE streaming');
      logger.info('Note: Clients must accept both application/json and text/event-stream');
      
      _addExampleTools(server);
      _addExampleResources(server);
      _addExamplePrompts(server);

      logger.info('StreamableHTTP SSE server ready');
      logger.info('- Tools: ${server.getTools().length}');
      logger.info('- Resources: ${server.getResources().length}');
      logger.info('- Prompts: ${server.getPrompts().length}');
      
      await Future.delayed(const Duration(seconds: 1));
      
      server.dispose();
    },
    (error) {
      logger.severe('Failed to start StreamableHTTP SSE server: $error');
    },
  );
}

/// Example 4: Streamable HTTP server (JSON mode)
Future<void> exampleStreamableHttpJsonServer(Logger logger) async {
  logger.info('\n=== Example 4: Streamable HTTP Server (JSON Mode) ===');

  final serverResult = await McpServer.createAndStart(
    config: McpServer.productionConfig(
      name: 'StreamableHTTP JSON Server',
      version: '1.0.0',
    ),
    transportConfig: TransportConfig.streamableHttp(
      host: 'localhost',
      port: 8084,
      endpoint: '/mcp',
      isJsonResponseEnabled: true, // JSON response mode
      fallbackPorts: [8085, 8086],
    ),
  );

  await serverResult.fold(
    (server) async {
      logger.info('StreamableHTTP server started on http://localhost:8084/mcp');
      logger.info('Response mode: JSON (single response)');
      logger.info('Note: Clients must still accept both application/json and text/event-stream');
      
      _addExampleTools(server);
      _addExampleResources(server);
      _addExamplePrompts(server);

      logger.info('StreamableHTTP JSON server ready');
      logger.info('- Tools: ${server.getTools().length}');
      logger.info('- Resources: ${server.getResources().length}');
      logger.info('- Prompts: ${server.getPrompts().length}');
      
      await Future.delayed(const Duration(seconds: 1));
      
      server.dispose();
    },
    (error) {
      logger.severe('Failed to start StreamableHTTP JSON server: $error');
    },
  );
}

/// Example 5: Production configuration
Future<void> exampleProductionServer(Logger logger) async {
  logger.info('\n=== Example 5: Production Server ===');

  final serverResult = await McpServer.createAndStart(
    config: McpServer.productionConfig(
      name: 'Production MCP Server',
      version: '2.0.0',
      capabilities: ServerCapabilities(
        tools: ToolsCapability(listChanged: true),
        resources: ResourcesCapability(
          listChanged: true,
          subscribe: true,
        ),
        prompts: PromptsCapability(listChanged: true),
        logging: LoggingCapability(),
        progress: ProgressCapability(supportsProgress: true),
      ),
    ),
    transportConfig: TransportConfig.sse(
      host: '0.0.0.0', // Bind to all interfaces
      port: 8443,
      authToken: 'production-secure-token',
      fallbackPorts: [8444, 8445, 8446],
    ),
  );

  await serverResult.fold(
    (server) async {
      logger.info('Production server started on http://0.0.0.0:8443/sse');
      
      // Add comprehensive functionality
      _addAdvancedTools(server, logger);
      _addAdvancedResources(server, logger);
      _addAdvancedPrompts(server, logger);

      logger.info('Production server ready with full capabilities');
      
      await Future.delayed(const Duration(seconds: 1));
      
      server.dispose();
    },
    (error) {
      logger.severe('Failed to start production server: $error');
    },
  );
}

/// Add example tools
void _addExampleTools(Server server) {
  server.addTool(
    name: 'calculator',
    description: 'Perform basic calculations',
    inputSchema: {
      'type': 'object',
      'properties': {
        'operation': {
          'type': 'string',
          'enum': ['add', 'subtract', 'multiply', 'divide'],
        },
        'a': {'type': 'number'},
        'b': {'type': 'number'},
      },
      'required': ['operation', 'a', 'b'],
    },
    handler: (args) async {
      final operation = args['operation'] as String;
      final a = (args['a'] as num).toDouble();
      final b = (args['b'] as num).toDouble();

      double result;
      switch (operation) {
        case 'add':
          result = a + b;
          break;
        case 'subtract':
          result = a - b;
          break;
        case 'multiply':
          result = a * b;
          break;
        case 'divide':
          if (b == 0) {
            return CallToolResult(
              content: [TextContent(text: 'Error: Division by zero')],
              isError: true,
            );
          }
          result = a / b;
          break;
        default:
          return CallToolResult(
            content: [TextContent(text: 'Error: Unknown operation')],
            isError: true,
          );
      }

      return CallToolResult(
        content: [TextContent(text: 'Result: $result')],
      );
    },
  );
}

/// Add example resources
void _addExampleResources(Server server) {
  server.addResource(
    uri: 'server://status',
    name: 'Server Status',
    description: 'Current server status information',
    mimeType: 'application/json',
    handler: (uri, params) async {
      final health = server.getHealth();
      return ReadResourceResult(
        contents: [
          ResourceContentInfo(
            uri: uri,
            mimeType: 'application/json',
            text: '''
{
  "status": "running",
  "server_name": "${server.name}",
  "server_version": "${server.version}",
  "uptime_seconds": ${health.uptime.inSeconds},
  "connected_sessions": ${health.connectedSessions},
  "registered_tools": ${health.registeredTools}
}
''',
          ),
        ],
      );
    },
  );
}

/// Add example prompts
void _addExamplePrompts(Server server) {
  server.addPrompt(
    name: 'greeting',
    description: 'Generate a greeting message',
    arguments: [
      PromptArgument(
        name: 'name',
        description: 'Name to greet',
        required: true,
      ),
      PromptArgument(
        name: 'formal',
        description: 'Use formal tone',
        required: false,
      ),
    ],
    handler: (args) async {
      final name = args['name'] as String;
      final formal = args['formal'] as bool? ?? false;

      final tone = formal ? 'formal' : 'casual';
      final greeting = formal 
          ? 'Good day, $name. I hope you are well.'
          : 'Hey $name! How\'s it going?';

      return GetPromptResult(
        description: 'A $tone greeting for $name',
        messages: [
          Message(
            role: 'assistant',
            content: TextContent(text: greeting),
          ),
        ],
      );
    },
  );
}

/// Add advanced tools for production example
void _addAdvancedTools(Server server, Logger logger) {
  _addExampleTools(server);
  
  server.addTool(
    name: 'system_info',
    description: 'Get detailed system information',
    inputSchema: {
      'type': 'object',
      'properties': {
        'format': {
          'type': 'string',
          'enum': ['json', 'text'],
          'default': 'json',
        },
      },
    },
    handler: (args) async {
      final format = args['format'] as String? ?? 'json';
      final now = DateTime.now();
      
      if (format == 'json') {
        return CallToolResult(
          content: [TextContent(text: '''
{
  "timestamp": "${now.toIso8601String()}",
  "platform": "${Platform.operatingSystem}",
  "version": "${Platform.operatingSystemVersion}",
  "dart_version": "${Platform.version}"
}
''')],
        );
      } else {
        return CallToolResult(
          content: [TextContent(text: '''
System Information:
- Timestamp: ${now.toIso8601String()}
- Platform: ${Platform.operatingSystem}
- OS Version: ${Platform.operatingSystemVersion}
- Dart Version: ${Platform.version}
''')],
        );
      }
    },
  );
}

/// Add advanced resources for production example
void _addAdvancedResources(Server server, Logger logger) {
  _addExampleResources(server);
  
  server.addResource(
    uri: 'metrics://performance',
    name: 'Performance Metrics',
    description: 'Server performance metrics',
    mimeType: 'application/json',
    handler: (uri, params) async {
      final health = server.getHealth();
      return ReadResourceResult(
        contents: [
          ResourceContentInfo(
            uri: uri,
            mimeType: 'application/json',
            text: '''
{
  "uptime_ms": ${health.uptime.inMilliseconds},
  "memory_usage": "monitoring_not_implemented",
  "request_count": "monitoring_not_implemented",
  "active_sessions": ${health.connectedSessions}
}
''',
          ),
        ],
      );
    },
  );
}

/// Add advanced prompts for production example
void _addAdvancedPrompts(Server server, Logger logger) {
  _addExamplePrompts(server);
  
  server.addPrompt(
    name: 'code_review',
    description: 'Generate code review prompt',
    arguments: [
      PromptArgument(
        name: 'language',
        description: 'Programming language',
        required: true,
      ),
      PromptArgument(
        name: 'focus',
        description: 'Review focus area',
        required: false,
      ),
    ],
    handler: (args) async {
      final language = args['language'] as String;
      final focus = args['focus'] as String? ?? 'general';

      return GetPromptResult(
        description: 'Code review prompt for $language ($focus focus)',
        messages: [
          Message(
            role: 'system',
            content: TextContent(
              text: 'You are an expert $language developer. '
                   'Focus on $focus aspects of the code review.',
            ),
          ),
          Message(
            role: 'user',
            content: TextContent(
              text: 'Please review the following $language code.',
            ),
          ),
        ],
      );
    },
  );
}