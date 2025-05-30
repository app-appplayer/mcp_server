import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:mcp_server/mcp_server.dart';

final Logger _logger = Logger.getLogger('mcp_server_example');

void main(List<String> args) async {
  _logger.setLevel(LogLevel.debug);

  // MCP STDIO Mode
  if (args.contains('--mcp-stdio-mode')) {
    await startMcpServer(mode: 'stdio');
  } else {
    // SSE Mode
    int port = 8999;
    await startMcpServer(mode: 'sse', port: port);
  }
}

Future<void> startMcpServer({required String mode, int port = 8080}) async {
  try {
    // Create server with capabilities
    final server = McpServer.createServer(
      name: 'Flutter MCP Demo',
      version: '1.0.0',
      capabilities: ServerCapabilities(
        tools: true,
        toolsListChanged: true,
        resources: true,
        resourcesListChanged: true,
        prompts: true,
        promptsListChanged: true,
      ),
    );

    // Register tools, resources, and prompts
    _registerTools(server);
    _registerResources(server);
    _registerPrompts(server);

    // Create transport based on mode
    ServerTransport transport;
    if (mode == 'stdio') {
      _logger.debug('Starting server in STDIO mode');
      transport = McpServer.createStdioTransport();
    } else {
      _logger.debug('Starting server in SSE mode on port $port');
      transport = McpServer.createSseTransport(
        endpoint: '/sse',
        messagesEndpoint: '/message',
        port: port,
        fallbackPorts: [
          port + 1,
          port + 2,
          port + 3
        ], // Try additional ports if needed
      );
    }

    // Set up transport closure handling
    transport.onClose.then((_) {
      _logger.debug('Transport closed, shutting down.');
      exit(0);
    });

    // Connect server to transport
    server.connect(transport);

    // Send initial log message
    server.sendLog(McpLogLevel.info, 'Flutter MCP Server started successfully');

    if (mode == 'sse') {
      _logger.debug('SSE Server is running on:');
      _logger.debug('- SSE endpoint:     http://localhost:$port/sse');
      _logger.debug('- Message endpoint: http://localhost:$port/message');
      _logger.debug('Press Ctrl+C to stop the server');
    } else {
      _logger.debug('STDIO Server initialized and connected to transport');
    }
  } catch (e, stackTrace) {
    _logger.debug('Error initializing MCP server: $e');
    _logger.debug(stackTrace as String);
    exit(1);
  }
}

void _registerTools(Server server) {
  // Hello world tool
  server.addTool(
    name: 'hello',
    description: 'Says hello to someone',
    inputSchema: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'description': 'Name to say hello to'}
      },
      'required': []
    },
    handler: (args, headers) async {
      final name = args['name'] ?? 'world';
      return CallToolResult([TextContent(text: 'Hello, $name!')]);
    },
  );

  // Calculator tool
  server.addTool(
    name: 'calculator',
    description: 'Perform basic arithmetic operations',
    inputSchema: {
      'type': 'object',
      'properties': {
        'operation': {
          'type': 'string',
          'enum': ['add', 'subtract', 'multiply', 'divide'],
          'description': 'Mathematical operation to perform'
        },
        'a': {'type': 'number', 'description': 'First operand'},
        'b': {'type': 'number', 'description': 'Second operand'}
      },
      'required': ['operation', 'a', 'b']
    },
    handler: (args, headers) async {
      final operation = args['operation'] as String;
      final a = (args['a'] is int)
          ? (args['a'] as int).toDouble()
          : args['a'] as double;
      final b = (args['b'] is int)
          ? (args['b'] as int).toDouble()
          : args['b'] as double;

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
            throw McpError('Cannot divide by zero');
          }
          result = a / b;
          break;
        default:
          throw McpError('Unknown operation: $operation');
      }

      return CallToolResult([TextContent(text: 'Result: $result')]);
    },
  );

  // Date and time tool
// Date and time tool
  server.addTool(
    name: 'currentDateTime',
    description: 'Get the current date and time',
    inputSchema: {
      'type': 'object',
      'properties': {
        'format': {
          'type': 'string',
          'description': 'Output format (full, date, time)',
          'default': 'full'
        }
      },
      'required': []
    },
    handler: (args, headers) async {
      try {
        _logger.debug("[DateTime Tool] Received args: $args");

        String format;
        if (args['format'] == null) {
          format = 'full';
        } else if (args['format'] is String) {
          format = args['format'] as String;
        } else {
          format = args['format'].toString();
        }

        _logger.debug("[DateTime Tool] Using format: $format");

        final now = DateTime.now();
        _logger.debug("[DateTime Tool] Current DateTime: $now");

        String result;
        switch (format) {
          case 'date':
            result =
                '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
            break;
          case 'time':
            try {
              final hour = now.hour.toString().padLeft(2, '0');
              final minute = now.minute.toString().padLeft(2, '0');
              final second = now.second.toString().padLeft(2, '0');
              result = '$hour:$minute:$second';
            } catch (e) {
              _logger.debug("[DateTime Tool] Error formatting time: $e");
              result = "Error formatting time: $e";
            }
            break;
          case 'full':
          default:
            try {
              result = now.toIso8601String();
            } catch (e) {
              _logger.debug("[DateTime Tool] Error with ISO format: $e");
              result =
                  "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} " +
                      "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
            }
            break;
        }

        _logger.debug("[DateTime Tool] Result: $result");
        return CallToolResult([TextContent(text: result)]);
      } catch (e, stackTrace) {
        _logger.debug("[DateTime Tool] Unexpected error: $e");
        _logger.debug("[DateTime Tool] Stack trace: $stackTrace");
        return CallToolResult(
            [TextContent(text: "Error getting date/time: $e")],
            isError: true);
      }
    },
  );
}

void _registerResources(Server server) {
  // System info resource
  server.addResource(
      uri: 'flutter://system-info',
      name: 'System Information',
      description: 'Detailed information about the current system',
      mimeType: 'application/json',
      uriTemplate: {'type': 'object', 'properties': {}},
      handler: (uri, params, headers) async {
        final systemInfo = {
          'operatingSystem': Platform.operatingSystem,
          'operatingSystemVersion': Platform.operatingSystemVersion,
          'localHostname': Platform.localHostname,
          'numberOfProcessors': Platform.numberOfProcessors,
          'localeName': Platform.localeName,
          'executable': Platform.executable,
          'resolvedExecutable': Platform.resolvedExecutable,
          'script': Platform.script.toString(),
        };

        final contents = systemInfo.entries
            .map((entry) => ResourceContent(
                  uri: 'flutter://system-info/${entry.key}',
                  text: '${entry.key}: ${entry.value}',
                ))
            .toList();

        return ReadResourceResult(
          content: jsonEncode(systemInfo),
          mimeType: 'application/json',
          contents: contents,
        );
      });

  // Environment variables resource
  server.addResource(
      uri: 'flutter://env-vars',
      name: 'Environment Variables',
      description: 'List of system environment variables',
      mimeType: 'application/json',
      uriTemplate: {'type': 'object', 'properties': {}},
      handler: (uri, params, headers) async {
        final envVars = Platform.environment;
        final contents = envVars.entries
            .map((entry) => ResourceContent(
                  uri: 'flutter://env-vars/${entry.key}',
                  text: '${entry.key}: ${entry.value}',
                ))
            .toList();

        return ReadResourceResult(
          content: jsonEncode(envVars),
          mimeType: 'application/json',
          contents: contents,
        );
      });

  // Sample file resource with URI template
  server.addResource(
    uri: 'file://{path}',
    name: 'File Resource',
    description: 'Access files on the system',
    mimeType: 'application/octet-stream',
    uriTemplate: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Path to the file'}
      }
    },
    handler: (uri, params, headers) async {
      try {
        // Extract path from parameters if not provided in URI
        String? path = params['path'] ?? uri.substring('file://'.length);

        if (path == null || path.isEmpty) {
          throw McpError('No path provided');
        }

        // Security check - define your own temp directory logic without path_provider
        final tempDir = Directory.systemTemp;
        if (!path.startsWith(tempDir.path)) {
          throw McpError('Access denied to path outside of temp directory');
        }

        // Read file
        final file = File(path);
        if (!await file.exists()) {
          throw McpError('File not found: $path');
        }

        final contents = await file.readAsString();
        String mimeType = 'text/plain';

        // Simple mime type detection
        if (path.endsWith('.json')) {
          mimeType = 'application/json';
        } else if (path.endsWith('.html')) {
          mimeType = 'text/html';
        } else if (path.endsWith('.css')) {
          mimeType = 'text/css';
        } else if (path.endsWith('.js')) {
          mimeType = 'application/javascript';
        }

        return ReadResourceResult(
          content: contents,
          mimeType: mimeType,
          contents: [
            ResourceContent(
              uri: 'file://$path',
              text: contents,
            )
          ],
        );
      } catch (e) {
        throw McpError('Error reading file: $e');
      }
    },
  );
}

void _registerPrompts(Server server) {
  // Simple greeting prompt
  server.addPrompt(
    name: 'greeting',
    description: 'Generate a greeting for a user',
    arguments: [
      PromptArgument(
        name: 'name',
        description: 'Name of the person to greet',
        required: true,
      ),
      PromptArgument(
        name: 'formal',
        description: 'Whether to use formal greeting style',
        required: false,
      ),
    ],
    handler: (args, headers) async {
      final name = args['name'] as String;
      final formal = args['formal'] as bool? ?? false;

      final String systemPrompt = formal
          ? 'You are a formal assistant. Address the user with respect and formality.'
          : 'You are a friendly assistant. Be warm and casual in your tone.';

      final messages = [
        Message(
          role: MessageRole.system.toString().split('.').last,
          content: TextContent(text: systemPrompt),
        ),
        Message(
          role: MessageRole.user.toString().split('.').last,
          content: TextContent(text: 'Please greet $name'),
        ),
      ];

      return GetPromptResult(
        description: 'A ${formal ? 'formal' : 'casual'} greeting for $name',
        messages: messages,
      );
    },
  );

  // Code review prompt
  server.addPrompt(
    name: 'codeReview',
    description: 'Generate a code review for a code snippet',
    arguments: [
      PromptArgument(
        name: 'code',
        description: 'Code to review',
        required: true,
      ),
      PromptArgument(
        name: 'language',
        description: 'Programming language of the code',
        required: true,
      ),
    ],
    handler: (args, headers) async {
      final code = args['code'] as String;
      final language = args['language'] as String;

      final systemPrompt = '''
You are an expert code reviewer. Review the provided code with these guidelines:
1. Identify potential bugs or issues
2. Suggest optimizations for performance or readability
3. Highlight good practices used in the code
4. Provide constructive feedback for improvements
Be specific in your feedback and provide code examples when suggesting changes.
''';

      final messages = [
        Message(
          role: MessageRole.system.toString().split('.').last,
          content: TextContent(text: systemPrompt),
        ),
        Message(
          role: MessageRole.user.toString().split('.').last,
          content: TextContent(
              text:
                  'Please review this $language code:\n\n```$language\n$code\n```'),
        ),
      ];

      return GetPromptResult(
        description: 'Code review for $language code',
        messages: messages,
      );
    },
  );
}
