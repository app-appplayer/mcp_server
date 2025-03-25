# MCP Server

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

This package implements the Model Context Protocol (MCP) specification version `2024-11-05`.

The protocol version is crucial for ensuring compatibility between MCP clients and servers. Each release of this package may support different protocol versions, so it's important to:

- Check the CHANGELOG.md for protocol version updates
- Ensure client and server protocol versions are compatible
- Stay updated with the latest MCP specification

### Version Compatibility

- Supported protocol version: 2024-11-05
- Compatibility: Tested with latest MCP client implementations

For the most up-to-date information on protocol versions and compatibility, refer to the [Model Context Protocol specification](https://spec.modelcontextprotocol.io).

## Getting Started

### Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  mcp_server: ^0.1.0
```

Or install via command line:

```bash
flutter pub add mcp_server
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
        },
        'a': {'type': 'number'},
        'b': {'type': 'number'},
      },
      'required': ['operation', 'a', 'b'],
    },
    handler: (arguments) async {
      final operation = arguments['operation'] as String;
      final a = arguments['a'] as num;
      final b = arguments['b'] as num;
      
      double result;
      switch (operation) {
        case 'add':
          result = (a + b).toDouble();
          break;
        case 'subtract':
          result = (a - b).toDouble();
          break;
        case 'multiply':
          result = (a * b).toDouble();
          break;
        case 'divide':
          if (b == 0) {
            return CallToolResult(
              content: [TextContent(text: 'Division by zero error')],
              isError: true,
            );
          }
          result = (a / b).toDouble();
          break;
        default:
          return CallToolResult(
            content: [TextContent(text: 'Unknown operation: $operation')],
            isError: true,
          );
      }
      
      return CallToolResult(
        content: [TextContent(text: result.toString())],
      );
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
          ResourceContent(
            resource: Resource(
              uri: uri.toString(),
              name: 'Current Time',
              mimeType: 'text/plain',
            ),
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
    ],
    handler: (arguments) async {
      final name = arguments?['name'] as String? ?? 'User';
      
      return GetPromptResult(
        description: 'A friendly greeting',
        messages: [
          Message(
            role: MessageRole.user,
            content: TextContent(text: 'Hello, $name!'),
          ),
        ],
      );
    },
  );

  // Connect to transport
  final transport = rMcpServer.createStdioTransport();
  await server.connect(transport);
}
```

## Core Concepts

### Server

The `McpServer` is your core interface to the MCP protocol. It handles connection management, protocol compliance, and message routing:

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
    return ReadResourceResult(
      contents: [
        ResourceContent(
          resource: Resource(
            uri: uri.toString(),
            name: 'App Configuration',
            mimeType: 'text/plain',
          ),
        ),
      ],
    );
  },
);

// Dynamic resource with parameters
server.addResourceTemplate(
  uriTemplate: 'users://{userId}/profile',
  name: 'User Profile',
  description: 'Profile data for specific user',
  mimeType: 'text/plain',
  handler: (uri, params) async {
    final userId = params['userId'];
    // Fetch user data...
    
    return ReadResourceResult(
      contents: [
        ResourceContent(
          resource: Resource(
            uri: uri.toString(),
            name: 'User Profile',
            mimeType: 'text/plain',
          ),
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
  name: 'search-web',
  description: 'Search the web for information',
  inputSchema: {
    'type': 'object',
    'properties': {
      'query': {'type': 'string'},
      'maxResults': {'type': 'number'},
    },
    'required': ['query'],
  },
  handler: (arguments) async {
    final query = arguments['query'] as String;
    final maxResults = arguments['maxResults'] as int? ?? 5;
    
    // Perform web search...
    
    return CallToolResult(
      content: [TextContent(text: 'Search results here')],
    );
  },
);
```

### Prompts

Prompts are reusable templates that help LLMs interact with your server effectively:

```dart
server.addPrompt(
  name: 'analyze-code',
  description: 'Analyze code for potential issues',
  arguments: [
    PromptArgument(
      name: 'code',
      description: 'Code to analyze',
      required: true,
    ),
    PromptArgument(
      name: 'language',
      description: 'Programming language',
      required: false,
    ),
  ],
  handler: (arguments) async {
    final code = arguments?['code'] as String? ?? '';
    final language = arguments?['language'] as String? ?? 'unknown';
    
    return GetPromptResult(
      description: 'Code analysis request',
      messages: [
        Message(
          role: MessageRole.user,
          content: TextContent(text: 'Please analyze this $language code:\n\n$code'),
        ),
      ],
    );
  },
);
```

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
final transport = FlutterMcpServer.createSseTransport(
  endpoint: '/sse',
  messagesEndpoint: '/messages',
);
await server.connect(transport);
```

## MCP Primitives

The MCP protocol defines three core primitives that servers can implement:

| Primitive | Control               | Description                                         | Example Use                  |
|-----------|-----------------------|-----------------------------------------------------|------------------------------|
| Prompts   | User-controlled       | Interactive templates invoked by user choice        | Slash commands, menu options |
| Resources | Application-controlled| Contextual data managed by the client application   | File contents, API responses |
| Tools     | Model-controlled      | Functions exposed to the LLM to take actions        | API calls, data updates      |

## Additional Examples

Check out the [example](https://github.com/app-appplayer/mcp_server/example) directory for a complete sample application.

## Resources

- [Model Context Protocol documentation](https://modelcontextprotocol.io)
- [Model Context Protocol specification](https://spec.modelcontextprotocol.io)
- [Officially supported servers](https://github.com/modelcontextprotocol/servers)

## Issues and Feedback

Please file any issues, bugs, or feature requests in our [issue tracker](https://github.com/app-appplayer/mcp_server/issues).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.