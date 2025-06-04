import 'dart:async';
import 'package:mcp_server/mcp_server.dart';

/// Modern example showing how to use the updated MCP server with Result types,
/// sealed classes, and modern Dart patterns.
/// 
/// TODO: This example needs major updates to match the current API:
/// - McpLogger class doesn't exist
/// - McpServer.simpleConfig() doesn't exist  
/// - Many capability classes don't exist (ToolsCapability, ResourcesCapability, etc.)
/// - addTool/addResource/addPrompt API signatures are different
/// - PromptMessage vs Message type mismatch
/// 
/// This file should be rewritten from scratch.
Future<void> main() async {
  final logger = Logger('server_example');

  logger.info('Modern MCP server example - simplified to match current API');
  
  // Only run a working example
  await _workingServerExample();
}

/// Working server example that matches current API
Future<void> _workingServerExample() async {
  final logger = Logger('working_server');
  
  // Create simple server
  final server = Server(
    name: 'Working Example Server',
    version: '1.0.0',
    capabilities: const ServerCapabilities(
      tools: true,
      resources: true,
      prompts: true,
    ),
  );

  // Add a simple tool
  server.addTool(
    name: 'test_tool',
    description: 'A simple test tool',
    inputSchema: {
      'type': 'object',
      'properties': {
        'input': {'type': 'string'}
      },
    },
    handler: (args) async {
      return CallToolResult(
        content: [TextContent(text: 'Test output: ${args['input'] ?? 'no input'}')],
      );
    },
  );

  logger.info('Working server example completed');
}

// TODO: The following examples need major API updates and are commented out

/*
/// Simple server example using basic configuration
Future<void> _simpleServerExample() async {
  final logger = McpLogger.getLogger('simple_server');
  
  // Create simple server configuration
  final config = McpServer.simpleConfig(
    name: 'SimpleServer',
    version: '1.0.0',
    enableDebugLogging: true,
  );

  // Create STDIO transport
  final transportResult = McpServer.createStdioTransport();
  
  transportResult.fold(
    (transport) async {
      logger.info('✅ STDIO transport created');
      
      // Create and start server
      final serverResult = await McpServer.createAndStart(
        config: config,
        transport: transport,
      );
      
      serverResult.fold(
        (server) {
          logger.info('✅ Simple server started');
          _setupBasicServer(server, logger);
        },
        (error) {
          logger.severe('❌ Failed to start server: $error');
        },
      );
    },
    (error) {
      logger.severe('❌ Failed to create transport: $error');
    },
  );
}

/// Production server example with SSE transport
Future<void> _productionServerExample() async {
  final logger = McpLogger.getLogger('production_server');
  
  // Create production server configuration
  final serverConfig = McpServer.productionConfig(
    name: 'ProductionServer',
    version: '2.0.0',
    capabilities: ServerCapabilities(
      experimental: {'advanced_features': true},
      tools: const ToolsCapability(listChanged: true),
      resources: const ResourcesCapability(subscribe: true, listChanged: true),
      prompts: const PromptsCapability(listChanged: true),
      logging: {},
    ),
  );

  // Create production SSE configuration
  final sseConfig = McpServer.productionSseConfig(
    port: 8080,
    fallbackPorts: [8081, 8082, 8083],
    authToken: 'secure-production-token',
  );

  logger.info('Creating production server with SSE transport...');

  final transportResult = McpServer.createSseTransport(sseConfig);
  
  transportResult.fold(
    (transport) async {
      logger.info('✅ SSE transport created on port ${sseConfig.port}');
      
      final serverResult = await McpServer.createAndStart(
        config: serverConfig,
        transport: transport,
      );
      
      serverResult.fold(
        (server) {
          logger.info('✅ Production server started');
          _setupProductionServer(server, logger);
        },
        (error) {
          logger.severe('❌ Failed to start production server: $error');
        },
      );
    },
    (error) {
      logger.severe('❌ Failed to create SSE transport: $error');
    },
  );
}

/// Comprehensive server example with tools, resources, and prompts
Future<void> _comprehensiveServerExample() async {
  final logger = McpLogger.getLogger('comprehensive_server');
  
  final config = McpServer.simpleConfig(
    name: 'ComprehensiveServer',
    version: '3.0.0',
    enableDebugLogging: true,
  );

  final transportResult = McpServer.createStdioTransport();
  
  transportResult.fold(
    (transport) async {
      final serverResult = await McpServer.createAndStart(
        config: config,
        transport: transport,
      );
      
      serverResult.fold(
        (server) {
          logger.info('✅ Comprehensive server started');
          _setupComprehensiveServer(server, logger);
          
          // Set up event listeners
          server.onConnect.listen((session) {
            logger.info('🔗 Client connected: ${session.id}');
          });
          
          server.onDisconnect.listen((session) {
            logger.info('🔌 Client disconnected: ${session.id}');
          });
        },
        (error) {
          logger.severe('❌ Failed to start comprehensive server: $error');
        },
      );
    },
    (error) {
      logger.severe('❌ Failed to create transport: $error');
    },
  );
}

/// Set up basic server with minimal tools and resources
void _setupBasicServer(Server server, Logger logger) {
  // Add a simple tool
  server.addTool(
    tool: Tool(
      name: 'echo',
      description: 'Echo back the input',
      inputSchema: {
        'type': 'object',
        'properties': {
          'message': {'type': 'string', 'description': 'Message to echo'},
        },
        'required': ['message'],
      },
    ),
    handler: (arguments) async {
      final message = arguments['message'] as String;
      logger.info('Echo tool called with: $message');
      return {'echo': message, 'timestamp': DateTime.now().toIso8601String()};
    },
  );

  // Add a simple resource
  server.addResource(
    resource: Resource(
      uri: 'memory://server-info',
      name: 'Server Information',
      description: 'Basic information about this server',
      mimeType: 'application/json',
    ),
    handler: (uri, params) async {
      return {
        'name': server.name,
        'version': server.version,
        'uptime': DateTime.now().difference(DateTime.now()).inSeconds,
        'capabilities': server.capabilities,
      };
    },
  );

  logger.info('Basic server setup complete');
}

/// Set up production server with comprehensive features
void _setupProductionServer(Server server, Logger logger) {
  // Advanced calculation tool
  server.addTool(
    tool: Tool(
      name: 'calculate',
      description: 'Perform mathematical calculations',
      inputSchema: {
        'type': 'object',
        'properties': {
          'expression': {'type': 'string', 'description': 'Mathematical expression'},
          'precision': {'type': 'integer', 'minimum': 1, 'maximum': 10, 'default': 2},
        },
        'required': ['expression'],
      },
    ),
    handler: (arguments) async {
      final expression = arguments['expression'] as String;
      final precision = arguments['precision'] as int? ?? 2;
      
      logger.info('Calculate tool called: $expression');
      
      // Simple calculation (in real app, use a proper math parser)
      if (expression.contains('+')) {
        final parts = expression.split('+');
        if (parts.length == 2) {
          final a = double.tryParse(parts[0].trim());
          final b = double.tryParse(parts[1].trim());
          if (a != null && b != null) {
            final result = (a + b).toStringAsFixed(precision);
            return {'result': result, 'expression': expression};
          }
        }
      }
      
      throw ArgumentError('Invalid expression: $expression');
    },
  );

  // System resource
  server.addResource(
    resource: Resource(
      uri: 'system://stats',
      name: 'System Statistics',
      description: 'Real-time system statistics',
      mimeType: 'application/json',
    ),
    handler: (uri, params) async {
      return {
        'timestamp': DateTime.now().toIso8601String(),
        'memory_usage': 'N/A', // In real app, get actual memory usage
        'cpu_usage': 'N/A',
        'active_connections': server.isConnected ? 1 : 0,
        'uptime_hours': DateTime.now().difference(DateTime.now()).inHours,
      };
    },
  );

  logger.info('Production server setup complete');
}

/// Set up comprehensive server with advanced features
void _setupComprehensiveServer(Server server, Logger logger) {
  // File system tool
  server.addTool(
    tool: Tool(
      name: 'list_files',
      description: 'List files in a directory',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Directory path'},
          'recursive': {'type': 'boolean', 'default': false},
        },
        'required': ['path'],
      },
    ),
    handler: (arguments) async {
      final path = arguments['path'] as String;
      final recursive = arguments['recursive'] as bool? ?? false;
      
      logger.info('List files tool called: $path (recursive: $recursive)');
      
      // Mock file listing
      return {
        'path': path,
        'files': [
          {'name': 'file1.txt', 'size': 1024, 'type': 'file'},
          {'name': 'subdir', 'size': 0, 'type': 'directory'},
        ],
        'recursive': recursive,
      };
    },
  );

  // Weather tool with progress reporting
  server.addTool(
    tool: Tool(
      name: 'get_weather',
      description: 'Get weather information for a location',
      inputSchema: {
        'type': 'object',
        'properties': {
          'location': {'type': 'string', 'description': 'Location name'},
          'units': {'type': 'string', 'enum': ['celsius', 'fahrenheit'], 'default': 'celsius'},
        },
        'required': ['location'],
      },
    ),
    handler: (arguments) async {
      final location = arguments['location'] as String;
      final units = arguments['units'] as String? ?? 'celsius';
      
      logger.info('Weather tool called for: $location');
      
      // Simulate API call with delay
      await Future.delayed(Duration(milliseconds: 500));
      
      return {
        'location': location,
        'temperature': units == 'celsius' ? 22 : 72,
        'units': units,
        'condition': 'Partly cloudy',
        'humidity': 65,
        'timestamp': DateTime.now().toIso8601String(),
      };
    },
  );

  // Dynamic resource with templates
  server.addResource(
    resource: Resource(
      uri: 'data://user/{userId}/profile',
      name: 'User Profile',
      description: 'User profile information',
      mimeType: 'application/json',
    ),
    handler: (uri, params) async {
      final userId = params['userId'] as String?;
      if (userId == null) {
        throw ArgumentError('userId parameter is required');
      }
      
      logger.info('User profile requested for: $userId');
      
      return {
        'userId': userId,
        'name': 'User $userId',
        'email': 'user$userId@example.com',
        'created': DateTime.now().subtract(Duration(days: 30)).toIso8601String(),
        'lastLogin': DateTime.now().subtract(Duration(hours: 2)).toIso8601String(),
      };
    },
  );

  // Add a prompt for code generation
  server.addPrompt(
    prompt: Prompt(
      name: 'code_review',
      description: 'Generate a code review prompt',
      arguments: [
        PromptArgument(
          name: 'language',
          description: 'Programming language',
          required: true,
        ),
        PromptArgument(
          name: 'code',
          description: 'Code to review',
          required: true,
        ),
      ],
    ),
    handler: (arguments) async {
      final language = arguments['language'] as String;
      final code = arguments['code'] as String;
      
      logger.info('Code review prompt generated for $language');
      
      return GetPromptResult(
        description: 'Code review for $language code',
        messages: [
          PromptMessage(
            role: PromptMessageRole.user,
            content: TextContent(
              text: 'Please review the following $language code:\n\n```$language\n$code\n```\n\n'
                    'Provide feedback on:\n'
                    '- Code quality and style\n'
                    '- Potential bugs or issues\n'
                    '- Performance considerations\n'
                    '- Best practices',
            ),
          ),
        ],
      );
    },
  );

  logger.info('Comprehensive server setup complete with ${server.isConnected ? 'active' : 'inactive'} connection');
}
*/