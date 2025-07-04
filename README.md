# MCP Server

## 🙌 Support This Project

If you find this package useful, consider supporting ongoing development on PayPal.

[![Donate](https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif)](https://www.paypal.com/ncp/payment/F7G56QD9LSJ92)  
Support makemind via [PayPal](https://www.paypal.com/ncp/payment/F7G56QD9LSJ92)

---

### 🔗 MCP Dart Package Family

- [`mcp_server`](https://pub.dev/packages/mcp_server): Exposes tools, resources, and prompts to LLMs. Acts as the AI server.
- [`mcp_client`](https://pub.dev/packages/mcp_client): Connects Flutter/Dart apps to MCP servers. Acts as the client interface.
- [`mcp_llm`](https://pub.dev/packages/mcp_llm): Bridges LLMs (Claude, OpenAI, etc.) to MCP clients/servers. Acts as the LLM brain.
- [`flutter_mcp`](https://pub.dev/packages/flutter_mcp): Complete Flutter plugin for MCP integration with platform features.
- [`flutter_mcp_ui_core`](https://pub.dev/packages/flutter_mcp_ui_core): Core models, constants, and utilities for Flutter MCP UI system. 
- [`flutter_mcp_ui_runtime`](https://pub.dev/packages/flutter_mcp_ui_runtime): Comprehensive runtime for building dynamic, reactive UIs through JSON specifications.
- [`flutter_mcp_ui_generator`](https://pub.dev/packages/flutter_mcp_ui_generator): JSON generation toolkit for creating UI definitions with templates and fluent API. 

---

A Dart plugin for implementing [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) servers. This plugin allows Flutter applications to expose data, functionality, and interaction patterns to Large Language Model (LLM) applications in a standardized way.

## Features

- Create MCP servers with standardized protocol support
- Expose data through **Resources**
- Provide functionality through **Tools**
- Define interaction patterns through **Prompts**
- Comprehensive session management with event streams
- Built-in resource caching for performance optimization
- Progress reporting and cancellation for long-running operations
- Extensive logging system with customizable levels and formatting
- Performance monitoring and metrics tracking
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
  mcp_server: ^1.0.2
```

Or install via command line:

```bash
dart pub add mcp_server
```

### Basic Usage

```dart
import 'package:mcp_server/mcp_server.dart';

void main() {
  // Create a server with simple boolean capabilities
  final server = Server(
    name: 'Example Server',
    version: '1.0.0',
    capabilities: ServerCapabilities.simple(
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
              content: [TextContent(text: 'Division by zero error')],
              isError: true,
            );
          }
          result = a / b;
          break;
        default:
          return CallToolResult(
            content: [TextContent(text: 'Unknown operation: $operation')],
            isError: true,
          );
      }
      
      return CallToolResult(content: [TextContent(text: 'Result: $result')]);
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
        contents: [
          ResourceContentInfo(
            uri: uri,
            text: now,
            mimeType: 'text/plain',
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

  // Connect to transport - old way (still supported)
  final transportResult = McpServer.createStdioTransport();
  final transport = transportResult.get();
  server.connect(transport);
}

// NEW: Simplified unified API (recommended)
void simplifiedMain() async {
  final serverResult = await McpServer.createAndStart(
    config: McpServer.simpleConfig(
      name: 'Example Server',
      version: '1.0.0',
    ),
    transportConfig: TransportConfig.stdio(),
  );

  await serverResult.fold(
    (server) async {
      // Add tools, resources, prompts as shown above
      
      // Server is already running
      await Future.delayed(const Duration(hours: 24));
    },
    (error) => print('Server failed: $error'),
  );
}
```

### Transport Configuration

The MCP Server now supports unified transport configuration:

```dart
// STDIO Transport
TransportConfig.stdio()

// SSE Transport  
TransportConfig.sse(
  host: 'localhost',
  port: 8080,
  endpoint: '/sse',
  authToken: 'optional-token',
)

// Streamable HTTP Transport - SSE Streaming Mode (default)
TransportConfig.streamableHttp(
  host: 'localhost', 
  port: 8081,
  endpoint: '/mcp',
  isJsonResponseEnabled: false, // SSE streaming mode (default)
)

// Streamable HTTP Transport - JSON Response Mode
TransportConfig.streamableHttp(
  host: 'localhost', 
  port: 8081,
  endpoint: '/mcp',
  isJsonResponseEnabled: true, // JSON response mode
)
```

## Core Concepts

### Server Capabilities

The MCP Server supports two ways to configure capabilities:

#### Simple Boolean Configuration
For basic usage and testing, use `ServerCapabilities.simple()`:

```dart
final server = Server(
  name: 'Simple Server',
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
```

#### Advanced Object-Based Configuration
For production use with detailed capability control:

```dart
final server = Server(
  name: 'Advanced Server',
  version: '1.0.0',
  capabilities: ServerCapabilities(
    tools: ToolsCapability(
      listChanged: true,
      supportsProgress: true,
      supportsCancellation: true,
    ),
    resources: ResourcesCapability(
      listChanged: true,
      subscribe: true,
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
```

### Server

The `Server` class is your core interface to the MCP protocol. It handles connection management, protocol compliance, and message routing:

```dart
final server = Server(
  name: 'My App',
  version: '1.0.0',
  capabilities: ServerCapabilities.simple(
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
      contents: [
        ResourceContentInfo(
          uri: uri,
          text: configData,
          mimeType: 'text/plain',
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
      contents: [
        ResourceContentInfo(
          uri: uri,
          text: content,
          mimeType: 'text/plain',
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
    
    return CallToolResult(content: [TextContent(text: result)]);
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

The MCP Server provides a powerful stream-based system for monitoring client session events:

```dart
// Create a logger
final logger = Logger('mcp_server.sessions');

// Listen for client connections
server.onConnect.listen((session) {
  logger.info('Client connected: ${session.id}');
  // Initialize session resources
});

// Listen for client disconnections
server.onDisconnect.listen((session) {
  logger.info('Client disconnected: ${session.id}');
  // Clean up session resources
});
```

The `ClientSession` object contains useful information:
- Session ID
- Connection timestamp
- Protocol version
- Client capabilities
- Client root directories

### Best Practices for Session Management

1. **Always handle both events**: Listen for both connection and disconnection events to maintain session integrity.

2. **Add error handling to your stream subscriptions**:
   ```dart
   server.onConnect.listen(
     (session) {
       // Normal event handling
     },
     onError: (error) {
       logger.severe('Error in connection stream: $error');
     },
   );
   ```

3. **Cancel subscriptions when no longer needed**:
   ```dart
   final subscription = server.onConnect.listen((session) { /* ... */ });
   
   // Later, when done:
   subscription.cancel();
   ```

4. **Use session events for state management**: Maintain application state based on session events.

5. **Track metrics for monitoring**: Count sessions, durations, and other metrics.

## Transport Layers

### Standard I/O

For command-line tools and direct integrations:

```dart
final transportResult = McpServer.createStdioTransport();
final transport = transportResult.get();
server.connect(transport);
```

### Server-Sent Events (SSE)

For HTTP-based communication:

```dart
final sseConfig = SseServerConfig(
  endpoint: '/sse',
  messagesEndpoint: '/messages',
  port: 8080,
);
final transportResult = McpServer.createSseTransport(sseConfig);
final transport = transportResult.get();
server.connect(transport);
```

### Streamable HTTP Transport

The Streamable HTTP transport supports two response modes:

#### SSE Streaming Mode (Default)
For real-time streaming of responses:

```dart
final serverResult = await McpServer.createAndStart(
  config: McpServer.simpleConfig(
    name: 'My Server',
    version: '1.0.0',
  ),
  transportConfig: TransportConfig.streamableHttp(
    host: 'localhost',
    port: 8081,
    endpoint: '/mcp',
    isJsonResponseEnabled: false, // SSE streaming mode
  ),
);
```

#### JSON Response Mode
For single JSON responses (simpler but no streaming):

```dart
final serverResult = await McpServer.createAndStart(
  config: McpServer.simpleConfig(
    name: 'My Server',
    version: '1.0.0',
  ),
  transportConfig: TransportConfig.streamableHttp(
    host: 'localhost',
    port: 8081,
    endpoint: '/mcp',
    isJsonResponseEnabled: true, // JSON response mode
  ),
);
```

**Important Notes:**
- The response mode is fixed at server startup and cannot be changed dynamically
- Clients must include both `application/json` and `text/event-stream` in their Accept headers regardless of the server's mode
- SSE mode allows streaming multiple responses, while JSON mode returns a single response

## Logging

The package includes a comprehensive logging utility with customizable levels and formatting:

```dart
// Create a named logger
final logger = Logger('mcp_server.example');

// Log at different levels
logger.severe('Connection failed: unable to connect to transport');
logger.warning('Resource cache is approaching capacity limit');
logger.info('Server started successfully on port 8080');
logger.fine('Session initialized with protocol version');

// Send structured logs to MCP client
server.sendLog(
  McpLogLevel.info, 
  'Operation registered',
  data: {
    'operationId': 'op-123',
    'sessionId': 'session-456',
    'type': 'tool:calculator',
    'timestamp': DateTime.now().toIso8601String(),
  }
);
```

## MCP Primitives

The MCP protocol defines three core primitives that servers can implement:

| Primitive | Control               | Description                                         | Example Use                  |
|-----------|-----------------------|-----------------------------------------------------|------------------------------|
| Prompts   | User-controlled       | Interactive templates invoked by user choice        | Slash commands, menu options |
| Resources | Application-controlled| Contextual data managed by the client application   | File contents, API responses |
| Tools     | Model-controlled      | Functions exposed to the LLM to take actions        | API calls, data updates      |

## Additional Features

### Session Operations

The Server class provides methods for managing long-running operations:

```dart
// Register operation for cancellation support
final operationId = server.registerOperation(sessionId, 'longProcess');

// Check if operation is cancelled
if (server.isOperationCancelled(operationId)) {
  return CallToolResult(
    [TextContent(text: 'Operation cancelled')],
    isError: true
  );
}

// Send progress updates
server.notifyProgress(operationId, 0.5, 'Halfway done');
```

### Resource Caching

The server includes built-in caching for resources to improve performance:

```dart
// Use built-in caching mechanism
final cached = server.getCachedResource(uri);
if (cached != null) {
  return cached.content;
}

// Fetch the resource (expensive operation)
final result = await fetchResource(uri, params);

// Cache for future use (5 minutes)
server.cacheResource(uri, result, Duration(minutes: 5));

// Invalidate cache when resource changes
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
        return CallToolResult(content: [TextContent(text: 'Operation cancelled')], isError: true);
      }
      
      // Update progress (0.0 to 1.0)
      server.notifyProgress(operationId, i / 10, 'Processing step $i of 10...');
      
      // Do work...
      await Future.delayed(Duration(seconds: 1));
    }
    
    return CallToolResult(content: [TextContent(text: 'Operation completed successfully')]);
  },
);
```

### Health Monitoring

The server provides built-in health metrics:

```dart
// Get server health statistics
final health = server.getHealth();

final logger = Logger('mcp_server.health');

logger.info('Server Health Summary - '
    'Running: ${health.isRunning}, '
    'Sessions: ${health.connectedSessions}, '
    'Uptime: ${health.uptime.inHours}h ${health.uptime.inMinutes % 60}m, '
    'Tools: ${health.registeredTools}, '
    'Resources: ${health.registeredResources}');

// Track custom metrics
server.incrementMetric('api_calls');
final timer = server.startTimer('operation_duration');
// ... perform operation
server.stopTimer('operation_duration');
```

## Error Handling

The MCP Server library includes standardized error codes and error handling mechanisms:

```dart
try {
  // Attempt an operation
  final result = await performOperation();
  return CallToolResult(content: [TextContent(text: result)]);
} catch (e) {
  // Return an error result
  return CallToolResult(
    content: [TextContent(text: 'Operation failed: ${e.toString()}')],
    isError: true,
  );
}
```

## Examples

Check out the [example](https://github.com/app-appplayer/mcp_server/tree/main/example) directory for a complete sample application.

## Related Articles

- [Building a Model Context Protocol Server with Dart: Connecting to Claude Desktop](https://dev.to/mcpdevstudio/building-a-model-context-protocol-server-with-dart-connecting-to-claude-desktop-2aad)
- [Building a Model Context Protocol Client with Dart: A Comprehensive Guide](https://dev.to/mcpdevstudio/building-a-model-context-protocol-client-with-dart-a-comprehensive-guide-4fdg)
- [Integrating AI with Flutter: A Comprehensive Guide to mcp_llm
  ](https://dev.to/mcpdevstudio/integrating-ai-with-flutter-a-comprehensive-guide-to-mcpllm-32f8)
- [Integrating AI with Flutter: Building Powerful Apps with LlmClient and mcp_client](https://dev.to/mcpdevstudio/integrating-ai-with-flutter-building-powerful-apps-with-llmclient-and-mcpclient-5b0i)
- [Integrating AI with Flutter: Creating AI Services with LlmServer and mcp_server](https://dev.to/mcpdevstudio/integrating-ai-with-flutter-creating-ai-services-with-llmserver-and-mcpserver-5084)
- [Integrating AI with Flutter: Connecting Multiple LLM Providers to MCP Ecosystem](https://dev.to/mcpdevstudio/integrating-ai-with-flutter-connecting-multiple-llm-providers-to-mcp-ecosystem-c3l)

## Resources

- [Model Context Protocol documentation](https://modelcontextprotocol.io)
- [Model Context Protocol specification](https://spec.modelcontextprotocol.io)
- [Officially supported servers](https://github.com/modelcontextprotocol/servers)

## Issues and Feedback

Please file any issues, bugs, or feature requests in our [issue tracker](https://github.com/app-appplayer/mcp_server/issues).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.