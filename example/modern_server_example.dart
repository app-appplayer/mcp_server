import 'dart:async';
import 'dart:io';
import 'package:mcp_server/mcp_server.dart';

/// Modern MCP server example demonstrating advanced features and best practices
/// 
/// This example shows:
/// - Two types of ServerCapabilities configuration
/// - Advanced transport setup
/// - Session management
/// - Progress tracking and cancellation
/// - Error handling with Result types
/// - Comprehensive logging
Future<void> main() async {
  final logger = Logger('modern_server');
  
  logger.info('🚀 Starting Modern MCP Server Example');
  
  // Show both capability configuration styles
  await _simpleCapabilitiesExample();
  await _advancedCapabilitiesExample();
  
  // Show different transport options
  await _stdioCommunicationExample();
  
  logger.info('✅ Modern MCP Server examples completed');
}

/// Example using simple boolean capabilities (good for testing/prototyping)
Future<void> _simpleCapabilitiesExample() async {
  final logger = Logger('simple_server');
  
  logger.info('📝 Simple Capabilities Example');
  
  final server = Server(
    name: 'Simple Modern Server',
    version: '1.0.0',
    capabilities: ServerCapabilities.simple(
      tools: true,
      toolsListChanged: true,
      resources: true,
      resourcesListChanged: true,
      prompts: true,
      promptsListChanged: true,
      sampling: true,
      logging: true,
      progress: true,
    ),
  );
  
  // Add session event listeners
  server.onConnect.listen((session) {
    logger.info('🔗 Client connected: ${session.id}');
  });
  
  server.onDisconnect.listen((session) {
    logger.info('🔌 Client disconnected: ${session.id}');
  });
  
  // Add tools with modern patterns
  _setupModernTools(server, logger);
  _setupModernResources(server, logger);
  _setupModernPrompts(server, logger);
  
  logger.info('✅ Simple server configured with ${server.getTools().length} tools');
}

/// Example using advanced object-based capabilities (good for production)
Future<void> _advancedCapabilitiesExample() async {
  final logger = Logger('advanced_server');
  
  logger.info('🔧 Advanced Capabilities Example');
  
  final server = Server(
    name: 'Advanced Modern Server',
    version: '2.0.0',
    capabilities: ServerCapabilities(
      tools: ToolsCapability(
        listChanged: true,
        supportsProgress: true,        // Tool execution progress
        supportsCancellation: true,    // Tool cancellation support
      ),
      resources: ResourcesCapability(
        listChanged: true,
        subscribe: true,               // Resource subscription support
      ),
      prompts: PromptsCapability(
        listChanged: true,
      ),
      sampling: SamplingCapability(),
      logging: LoggingCapability(),
      progress: ProgressCapability(
        supportsProgress: true,
      ),
    ),
  );
  
  // Add advanced tools with progress and cancellation
  _setupAdvancedTools(server, logger);
  
  logger.info('✅ Advanced server configured with enhanced capabilities');
}

/// Example showing STDIO communication with proper Result handling
Future<void> _stdioCommunicationExample() async {
  final logger = Logger('stdio_server');
  
  logger.info('📡 STDIO Communication Example');
  
  final server = Server(
    name: 'STDIO Communication Server',
    version: '1.0.0',
    capabilities: ServerCapabilities.simple(
      tools: true,
      resources: true,
      prompts: true,
    ),
  );
  
  // Add basic functionality
  _setupBasicFunctionality(server, logger);
  
  // Create transport with proper Result handling
  final transportResult = McpServer.createStdioTransport();
  
  if (transportResult.isSuccess) {
    final transport = transportResult.get();
    server.connect(transport);
    
    logger.info('🔗 Server connected to STDIO transport');
    logger.info('📞 Ready to receive MCP requests...');
    
    // Set up graceful shutdown
    ProcessSignal.sigint.watch().listen((signal) async {
      logger.info('🛑 Received SIGINT, shutting down gracefully...');
      server.dispose();
      exit(0);
    });
    
    // Keep server running
    await transport.onClose;
    logger.info('📴 Server disconnected');
  } else {
    final error = transportResult.failureOrNull;
    logger.severe('❌ Failed to create STDIO transport: $error');
  }
}

/// Set up modern tools with proper error handling and typing
void _setupModernTools(Server server, Logger logger) {
  // Calculator tool with comprehensive error handling
  server.addTool(
    name: 'calculator',
    description: 'Perform mathematical calculations with error handling',
    inputSchema: {
      'type': 'object',
      'properties': {
        'operation': {
          'type': 'string',
          'enum': ['add', 'subtract', 'multiply', 'divide'],
          'description': 'Mathematical operation to perform'
        },
        'a': {'type': 'number', 'description': 'First operand'},
        'b': {'type': 'number', 'description': 'Second operand'},
      },
      'required': ['operation', 'a', 'b'],
    },
    handler: (args) async {
      try {
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
              content: [TextContent(text: 'Error: Unknown operation: $operation')],
              isError: true,
            );
        }
        
        logger.info('Calculator: $a $operation $b = $result');
        
        return CallToolResult(
          content: [TextContent(text: 'Result: $result')],
        );
      } catch (e) {
        return CallToolResult(
          content: [TextContent(text: 'Error: Invalid input - $e')],
          isError: true,
        );
      }
    },
  );
  
  // System info tool
  server.addTool(
    name: 'system_info',
    description: 'Get current system information',
    inputSchema: {
      'type': 'object',
      'properties': {
        'format': {
          'type': 'string',
          'enum': ['json', 'text'],
          'default': 'text',
          'description': 'Output format'
        },
      },
    },
    handler: (args) async {
      final format = args['format'] as String? ?? 'text';
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

/// Set up modern resources with proper content handling
void _setupModernResources(Server server, Logger logger) {
  // Current time resource
  server.addResource(
    uri: 'time://current',
    name: 'Current Time',
    description: 'Get the current date and time in various formats',
    mimeType: 'application/json',
    handler: (uri, params) async {
      final format = params['format'] as String? ?? 'iso';
      final now = DateTime.now();
      
      String timeString;
      switch (format) {
        case 'iso':
          timeString = now.toIso8601String();
          break;
        case 'unix':
          timeString = now.millisecondsSinceEpoch.toString();
          break;
        case 'human':
          timeString = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
          break;
        default:
          timeString = now.toString();
      }
      
      return ReadResourceResult(
        contents: [
          ResourceContentInfo(
            uri: uri,
            mimeType: 'application/json',
            text: '{"current_time": "$timeString", "format": "$format"}',
          ),
        ],
      );
    },
  );
  
  // Server status resource
  server.addResource(
    uri: 'server://status',
    name: 'Server Status',
    description: 'Get current server status and health metrics',
    mimeType: 'application/json',
    handler: (uri, params) async {
      final health = server.getHealth();
      
      final statusJson = '''
{
  "status": "running",
  "server_name": "${server.name}",
  "server_version": "${server.version}",
  "uptime_seconds": ${health.uptime.inSeconds},
  "connected_sessions": ${health.connectedSessions},
  "registered_tools": ${health.registeredTools},
  "registered_resources": ${health.registeredResources},
  "registered_prompts": ${health.registeredPrompts},
  "start_time": "${health.startTime.toIso8601String()}"
}
''';
      
      return ReadResourceResult(
        contents: [
          ResourceContentInfo(
            uri: uri,
            mimeType: 'application/json',
            text: statusJson,
          ),
        ],
      );
    },
  );
}

/// Set up modern prompts with comprehensive message handling
void _setupModernPrompts(Server server, Logger logger) {
  // Code review prompt
  server.addPrompt(
    name: 'code_review',
    description: 'Generate a comprehensive code review prompt',
    arguments: [
      PromptArgument(
        name: 'language',
        description: 'Programming language (e.g., dart, python, javascript)',
        required: true,
      ),
      PromptArgument(
        name: 'code',
        description: 'Code to review',
        required: true,
      ),
      PromptArgument(
        name: 'focus',
        description: 'Review focus area (style, performance, security, all)',
        required: false,
        defaultValue: 'all',
      ),
    ],
    handler: (args) async {
      final language = args['language'] as String;
      final code = args['code'] as String;
      final focus = args['focus'] as String? ?? 'all';
      
      String reviewPrompt;
      switch (focus) {
        case 'style':
          reviewPrompt = 'Focus on code style, naming conventions, and readability.';
          break;
        case 'performance':
          reviewPrompt = 'Focus on performance optimizations and efficiency.';
          break;
        case 'security':
          reviewPrompt = 'Focus on security vulnerabilities and best practices.';
          break;
        default:
          reviewPrompt = 'Provide a comprehensive review covering style, performance, security, and best practices.';
      }
      
      final messages = [
        Message(
          role: 'system',
          content: TextContent(
            text: 'You are an expert $language developer and code reviewer. $reviewPrompt'
          ),
        ),
        Message(
          role: 'user',
          content: TextContent(
            text: 'Please review the following $language code:\n\n```$language\n$code\n```'
          ),
        ),
      ];
      
      return GetPromptResult(
        description: 'Code review for $language code (focus: $focus)',
        messages: messages,
      );
    },
  );
  
  // Meeting summarization prompt
  server.addPrompt(
    name: 'meeting_summary',
    description: 'Generate a meeting summary prompt',
    arguments: [
      PromptArgument(
        name: 'transcript',
        description: 'Meeting transcript or notes',
        required: true,
      ),
      PromptArgument(
        name: 'format',
        description: 'Summary format (bullet, paragraph, action_items)',
        required: false,
        defaultValue: 'bullet',
      ),
    ],
    handler: (args) async {
      final transcript = args['transcript'] as String;
      final format = args['format'] as String? ?? 'bullet';
      
      String formatInstruction;
      switch (format) {
        case 'bullet':
          formatInstruction = 'Format the summary as bullet points with clear categories.';
          break;
        case 'paragraph':
          formatInstruction = 'Format the summary as flowing paragraphs.';
          break;
        case 'action_items':
          formatInstruction = 'Focus on extracting and listing action items with owners and deadlines.';
          break;
        default:
          formatInstruction = 'Use a clear, organized format.';
      }
      
      final messages = [
        Message(
          role: 'system',
          content: TextContent(
            text: 'You are a professional meeting facilitator who excels at creating clear, actionable meeting summaries. $formatInstruction'
          ),
        ),
        Message(
          role: 'user',
          content: TextContent(
            text: 'Please summarize the following meeting:\n\n$transcript'
          ),
        ),
      ];
      
      return GetPromptResult(
        description: 'Meeting summary ($format format)',
        messages: messages,
      );
    },
  );
}

/// Set up advanced tools with progress tracking and cancellation
void _setupAdvancedTools(Server server, Logger logger) {
  // Long-running operation with progress tracking
  server.addTool(
    name: 'long_operation',
    description: 'Simulate a long-running operation with progress updates',
    inputSchema: {
      'type': 'object',
      'properties': {
        'duration': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 30,
          'default': 5,
          'description': 'Operation duration in seconds'
        },
        'steps': {
          'type': 'integer',
          'minimum': 3,
          'maximum': 20,
          'default': 10,
          'description': 'Number of progress steps'
        },
      },
    },
    handler: (args) async {
      final duration = args['duration'] as int? ?? 5;
      final steps = args['steps'] as int? ?? 10;
      final stepDuration = Duration(milliseconds: (duration * 1000 / steps).round());
      
      logger.info('Starting long operation: ${duration}s with $steps steps');
      
      for (int i = 0; i < steps; i++) {
        // Simulate work
        await Future.delayed(stepDuration);
        
        final progress = (i + 1) / steps;
        final message = 'Completed step ${i + 1} of $steps';
        
        // Note: In a real implementation, you would need the operation ID
        // server.notifyProgress(operationId, progress, message);
        
        logger.fine('Progress: ${(progress * 100).toStringAsFixed(1)}% - $message');
      }
      
      return CallToolResult(
        content: [TextContent(text: 'Long operation completed successfully in ${duration}s')],
      );
    },
  );
}

/// Set up basic functionality for communication example
void _setupBasicFunctionality(Server server, Logger logger) {
  // Echo tool
  server.addTool(
    name: 'echo',
    description: 'Echo back the input message',
    inputSchema: {
      'type': 'object',
      'properties': {
        'message': {'type': 'string', 'description': 'Message to echo'},
      },
      'required': ['message'],
    },
    handler: (args) async {
      final message = args['message'] as String;
      logger.info('Echo: $message');
      return CallToolResult(
        content: [TextContent(text: 'Echo: $message')],
      );
    },
  );
  
  // Ping resource
  server.addResource(
    uri: 'test://ping',
    name: 'Ping Test',
    description: 'Simple ping test resource',
    mimeType: 'text/plain',
    handler: (uri, params) async {
      return ReadResourceResult(
        contents: [
          ResourceContentInfo(
            uri: uri,
            mimeType: 'text/plain',
            text: 'pong - ${DateTime.now().toIso8601String()}',
          ),
        ],
      );
    },
  );
  
  // Hello prompt
  server.addPrompt(
    name: 'hello',
    description: 'Generate a friendly greeting',
    arguments: [
      PromptArgument(
        name: 'name',
        description: 'Name of the person to greet',
        required: false,
        defaultValue: 'World',
      ),
    ],
    handler: (args) async {
      final name = args['name'] as String? ?? 'World';
      
      return GetPromptResult(
        description: 'A friendly greeting',
        messages: [
          Message(
            role: 'assistant',
            content: TextContent(text: 'Hello, $name! How can I help you today?'),
          ),
        ],
      );
    },
  );
  
  logger.info('Basic functionality set up complete');
}