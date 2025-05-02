# MCP Server

## 🙌 Support This Project

If you find this package useful, consider supporting ongoing development on Patreon.

[![Support on Patreon](https://c5.patreon.com/external/logo/become_a_patron_button.png)](https://www.patreon.com/mcpdevstudio)

---

A Dart plugin for implementing [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) servers. This plugin allows Flutter applications to expose data, functionality, and interaction patterns to Large Language Model (LLM) applications in a standardized way.

## Features

- Create MCP servers with standardized protocol support
- Expose data through **Resources**
- Provide functionality through **Tools**
- Define interaction patterns through **Prompts**
- Multiple transport layers:
  - Standard I/O for local process communication
  - Server-Sent Events (SSE) for HTTP-based communication
- Cross-platform support: Android, iOS, web, Linux, Windows, macOS

## Protocol Version

This package implements the Model Context Protocol (MCP) specification versions `2024-11-05` and `2025-03-26`.

The protocol version is crucial for ensuring compatibility between MCP clients and servers. Each release of this package may support different protocol versions, so it's important to:

- Check the CHANGELOG.md for protocol version updates
- Ensure client and server protocol versions are compatible
- Stay updated with the latest MCP specification

## Getting Started

### Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  mcp_server: ^0.1.9
```

Or install via command line:

```bash
dart pub add mcp_server
```

### Basic Usage

```dart
import 'package:mcp_server/mcp_server.dart';

void main() {
  // Create a server
  final server = McpServer.createServer(
    name: 'Example Server',
    version: '1.0.0',
    capabilities: ServerCapabilities(
      tools: true,
      resources: true,
      prompts: true,
    ),
  );

  // Add a simple calculator tool
  server.addTool(
    name: 'calculator',
    description: 'Perform basic calculations',
    inputSchema: {
      'type': 'object',
      'properties': {
        'operation': {
          'type': 'string',
          'enum': ['add', 'subtract', 'multiply', 'divide'],
          'description': 'Mathematical operation to perform'
        },
        'a': {
          'type': 'number',
          'description': 'First operand'
        },
        'b': {
          'type': 'number',
          'description': 'Second operand'
        }
      },
      'required': ['operation', 'a', 'b']
    },
    handler: (arguments) async {
      final operation = arguments['operation'] as String;
      final a = (arguments['a'] is int) ? (arguments['a'] as int).toDouble() : arguments['a'] as double;
      final b = (arguments['b'] is int) ? (arguments['b'] as int).toDouble() : arguments['b'] as double;
      
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
              [TextContent(text: 'Division by zero error')],
              isError: true,
            );
          }
          result = a / b;
          break;
        default:
          return CallToolResult(
            [TextContent(text: 'Unknown operation: $operation')],
            isError: true,
          );
      }
      
      return CallToolResult([TextContent(text: 'Result: $result')]);
    },
  );

  // Add a resource
  server.addResource(
    uri: 'time://current',
    name: 'Current Time',
    description: 'Get the current date and time',
    mimeType: 'text/plain',
    handler: (uri, params) async {
      final now = DateTime.now().toString();
      
      return ReadResourceResult(
        content: now,
        mimeType: 'text/plain',
        contents: [
          ResourceContent(
            uri: uri,
            text: now,
          ),
        ],
      );
    },
  );

  // Add a template prompt
  server.addPrompt(
    name: 'greeting',
    description: 'Generate a customized greeting',
    arguments: [
      PromptArgument(
        name: 'name',
        description: 'Name to greet',
        required: true,
      ),
      PromptArgument(
        name: 'formal',
        description: 'Whether to use formal greeting style',
        required: false,
      ),
    ],
    handler: (arguments) async {
      final name = arguments['name'] as String;
      final formal = arguments['formal'] as bool? ?? false;

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

  // Connect to transport
  final transport = McpServer.createStdioTransport();
  server.connect(transport);
}
```

## Core Concepts

### Server

The `Server` class is your core interface to the MCP protocol. It handles connection management, protocol compliance, and message routing:

```dart
final server = McpServer.createServer(
  name: 'My App',
  version: '1.0.0',
  capabilities: ServerCapabilities(
    tools: true,
    resources: true,
    prompts: true,
  ),
);
```

### Resources

Resources are how you expose data to LLMs. They're similar to GET endpoints in a REST API - they provide data but shouldn't perform significant computation or have side effects:

```dart
// Static resource
server.addResource(
  uri: 'config://app',
  name: 'App Configuration',
  description: 'Application configuration data',
  mimeType: 'text/plain',
  handler: (uri, params) async {
    final configData = "app_name=MyApp\nversion=1.0.0\ndebug=false";
    
    return ReadResourceResult(
      content: configData,
      mimeType: 'text/plain',
      contents: [
        ResourceContent(
          uri: uri,
          text: configData,
        ),
      ],
    );
  },
);

// Resource with URI template
server.addResource(
  uri: 'file://{path}',
  name: 'File Resource',
  description: 'Access files on the system',
  mimeType: 'application/octet-stream',
  uriTemplate: {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Path to the file'
      }
    }
  },
  handler: (uri, params) async {
    // Extract path and read file content
    final path = params['path'] ?? uri.substring('file://'.length);
    final content = await File(path).readAsString();
    
    return ReadResourceResult(
      content: content,
      mimeType: 'text/plain',
      contents: [
        ResourceContent(
          uri: uri,
          text: content,
        ),
      ],
    );
  },
);
```

### Tools

Tools let LLMs take actions through your server. Unlike resources, tools are expected to perform computation and have side effects:

```dart
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
  handler: (args) async {
    final format = args['format'] as String? ?? 'full';
    final now = DateTime.now();
    
    String result;
    switch (format) {
      case 'date':
        result = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        break;
      case 'time':
        result = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
        break;
      case 'full':
      default:
        result = now.toIso8601String();
        break;
    }
    
    return CallToolResult([TextContent(text: result)]);
  },
);
```

### Prompts

Prompts are reusable templates that help LLMs interact with your server effectively:

```dart
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
  handler: (args) async {
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
        content: TextContent(text: 'Please review this $language code:\n\n```$language\n$code\n```'),
      ),
    ];

    return GetPromptResult(
      description: 'Code review for $language code',
      messages: messages,
    );
  },
);
```

## Session Management

The server provides a listener system for handling client session events:

```dart
// Register session connection listener
server.addSessionListener('connected', (session) {
  logger.info('Client connected: ${session.id}');
  // Perform session initialization
});

// Register session disconnection listener
server.addSessionListener('disconnected', (session) {
  logger.info('Client disconnected: ${session.id}');
  // Perform cleanup tasks
});
```

This feature allows you to:
- Monitor client connections and disconnections
- Automate session-specific initialization and cleanup
- Manage session resources
- Track connection statistics and logging

The `ClientSession` object contains useful information:
- Session ID
- Connection timestamp
- Protocol version
- Client capabilities
- Client root directories

## Transport Layers

### Standard I/O

For command-line tools and direct integrations:

```dart
final transport = McpServer.createStdioTransport();
await server.connect(transport);
```

### Server-Sent Events (SSE)

For HTTP-based communication:

```dart
final transport = McpServer.createSseTransport(
  endpoint: '/sse',
  messagesEndpoint: '/messages',
  port: 8080,
);
await server.connect(transport);
```

## Logging

The package includes a built-in logging utility:

```dart
/// Logging
final Logger _logger = Logger.getLogger('mcp_server.test');
_logger.setLevel(LogLevel.debug);

// Configure logging
_logger.configure(level: LogLevel.debug, includeTimestamp: true, useColor: true);

// Log messages at different levels
_logger.debug('Debugging information');
_logger.info('Important information');
_logger.warning('Warning message');
_logger.error('Error message');
```

## MCP Primitives

The MCP protocol defines three core primitives that servers can implement:

| Primitive | Control               | Description                                         | Example Use                  |
|-----------|-----------------------|-----------------------------------------------------|------------------------------|
| Prompts   | User-controlled       | Interactive templates invoked by user choice        | Slash commands, menu options |
| Resources | Application-controlled| Contextual data managed by the client application   | File contents, API responses |
| Tools     | Model-controlled      | Functions exposed to the LLM to take actions        | API calls, data updates      |

## Additional Features

### Resource Caching

The server includes built-in caching for resources to improve performance:

```dart
// Use built-in caching mechanism
final cached = server.getCachedResource(uri);
if (cached != null) {
  return cached.content;
}

// Cache a resource for future use
server.cacheResource(uri, result, Duration(minutes: 10));

// Invalidate cache
server.invalidateCache(uri);
```

### Progress Tracking

For long-running operations, you can report progress to clients:

```dart
server.addTool(
  name: 'longRunningOperation',
  description: 'Perform a long-running operation with progress reporting',
  inputSchema: { /* ... */ },
  handler: (args) async {
    // Register operation for progress tracking
    final operationId = server.registerOperation(sessionId, 'longRunningOperation');
    
    // Update progress as the operation progresses
    for (int i = 0; i < 10; i++) {
      // Check if operation was cancelled
      if (server.isOperationCancelled(operationId)) {
        return CallToolResult([TextContent(text: 'Operation cancelled')], isError: true);
      }
      
      // Update progress (0.0 to 1.0)
      server.notifyProgress(operationId, i / 10, 'Processing step $i of 10...');
      
      // Do work...
      await Future.delayed(Duration(seconds: 1));
    }
    
    return CallToolResult([TextContent(text: 'Operation completed successfully')]);
  },
);
```

### Health Monitoring

The server provides built-in health metrics:

```dart
// Get server health information
final health = server.getHealth();
_logger.debug('Server uptime: ${health.uptime.inSeconds} seconds');
_logger.debug('Connected sessions: ${health.connectedSessions}');
_logger.debug('Registered tools: ${health.registeredTools}');

// Track custom metrics
server.incrementMetric('api_calls');
final timer = server.startTimer('operation_duration');
// ... perform operation
server.stopTimer('operation_duration');
```

## Examples

Check out the [example](https://github.com/app-appplayer/mcp_server/tree/main/example) directory for a complete sample application.

## Resources

- [Model Context Protocol documentation](https://modelcontextprotocol.io)
- [Model Context Protocol specification](https://spec.modelcontextprotocol.io)
- [Officially supported servers](https://github.com/modelcontextprotocol/servers)

## Issues and Feedback

Please file any issues, bugs, or feature requests in our [issue tracker](https://github.com/app-appplayer/mcp_server/issues).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.