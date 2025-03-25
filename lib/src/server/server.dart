import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/models.dart';
import '../transport/transport.dart';

/// Main MCP Server class that handles all server-side protocol operations
class Server {
  /// Name of the MCP server
  final String name;

  /// Version of the MCP server implementation
  final String version;

  /// Server capabilities configuration
  final ServerCapabilities capabilities;

  /// Protocol version this server implements
  final String protocolVersion = "2024-11-05";

  /// Map of registered tools by name
  final Map<String, Tool> _tools = {};

  /// Map of tool handlers by name
  final Map<String, ToolHandler> _toolHandlers = {};

  /// Map of registered resources by URI
  final Map<String, Resource> _resources = {};

  /// Map of resource handlers by URI
  final Map<String, ResourceHandler> _resourceHandlers = {};

  /// Map of registered prompts by name
  final Map<String, Prompt> _prompts = {};

  /// Map of prompt handlers by name
  final Map<String, PromptHandler> _promptHandlers = {};

  /// Transport connection
  ServerTransport? _transport;

  /// Stream controller for handling incoming messages
  final _messageController = StreamController<JsonRpcMessage>.broadcast();

  /// Whether the server is currently connected
  bool get isConnected => _transport != null;

  /// Creates a new MCP server with the specified parameters
  Server({
    required this.name,
    required this.version,
    this.capabilities = const ServerCapabilities(),
  });

  /// Connect the server to a transport
  void connect(ServerTransport transport) {
    if (_transport != null) {
      throw McpError('Server is already connected to a transport');
    }

    _transport = transport;
    _transport!.onMessage.listen(_handleMessage);
    _transport!.onClose.then((_) {
      _onDisconnect();
    });

    // Set up server handlers
    _messageController.stream.listen((message) async {
      try {
        await _processMessage(message);
      } catch (e) {
        _sendErrorResponse(message.id, -32000, 'Internal error: $e');
      }
    });
  }

  /// Add a tool to the server
  void addTool({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required ToolHandler handler,
  }) {
    stderr.writeln('Adding tool: $name');
    stderr.writeln('Input schema: $inputSchema');

    if (_tools.containsKey(name)) {
      stderr.writeln('Tool with name "$name" already exists');
      throw McpError('Tool with name "$name" already exists');
    }

    final tool = Tool(
      name: name,
      description: description,
      inputSchema: inputSchema,
    );

    _tools[name] = tool;
    _toolHandlers[name] = handler;

    stderr.writeln('Tool added successfully: $name');
    stderr.writeln('Total tools: ${_tools.length}');

    // Notify clients about tool changes if connected
    if (isConnected && capabilities.tools && capabilities.toolsListChanged) {
      _sendNotification('tools/listChanged', {});
    }
  }

  /// Add a resource to the server
  void addResource({
    required String uri,
    required String name,
    required String description,
    required String mimeType,
    Map<String, dynamic>? uriTemplate,
    required ResourceHandler handler,
  }) {
    if (_resources.containsKey(uri)) {
      throw McpError('Resource with URI "$uri" already exists');
    }

    final resource = Resource(
      uri: uri,
      name: name,
      description: description,
      mimeType: mimeType,
      uriTemplate: uriTemplate,
    );

    _resources[uri] = resource;
    _resourceHandlers[uri] = handler;

    // Notify clients about resource changes if connected
    if (isConnected && capabilities.resources && capabilities.resourcesListChanged) {
      _sendNotification('resources/listChanged', {});
    }
  }

  /// Add a prompt to the server
  void addPrompt({
    required String name,
    required String description,
    required List<PromptArgument> arguments,
    required PromptHandler handler,
  }) {
    if (_prompts.containsKey(name)) {
      throw McpError('Prompt with name "$name" already exists');
    }

    final prompt = Prompt(
      name: name,
      description: description,
      arguments: arguments,
    );

    _prompts[name] = prompt;
    _promptHandlers[name] = handler;

    // Notify clients about prompt changes if connected
    if (isConnected && capabilities.prompts && capabilities.promptsListChanged) {
      _sendNotification('prompts/listChanged', {});
    }
  }

  /// Remove a tool from the server
  void removeTool(String name) {
    if (!_tools.containsKey(name)) {
      throw McpError('Tool with name "$name" does not exist');
    }

    _tools.remove(name);
    _toolHandlers.remove(name);

    // Notify clients about tool changes if connected
    if (isConnected && capabilities.tools && capabilities.toolsListChanged) {
      _sendNotification('tools/listChanged', {});
    }
  }

  /// Remove a resource from the server
  void removeResource(String uri) {
    if (!_resources.containsKey(uri)) {
      throw McpError('Resource with URI "$uri" does not exist');
    }

    _resources.remove(uri);
    _resourceHandlers.remove(uri);

    // Notify clients about resource changes if connected
    if (isConnected && capabilities.resources && capabilities.resourcesListChanged) {
      _sendNotification('resources/listChanged', {});
    }
  }

  /// Remove a prompt from the server
  void removePrompt(String name) {
    if (!_prompts.containsKey(name)) {
      throw McpError('Prompt with name "$name" does not exist');
    }

    _prompts.remove(name);
    _promptHandlers.remove(name);

    // Notify clients about prompt changes if connected
    if (isConnected && capabilities.prompts && capabilities.promptsListChanged) {
      _sendNotification('prompts/listChanged', {});
    }
  }

  /// Send a logging notification to the client
  void sendLog(LogLevel level, String message, {String? logger, Map<String, dynamic>? data}) {
    if (!isConnected) return;

    final params = {
      'level': level.index,
      'message': message,
    };

    if (logger != null) {
      params['logger'] = logger;
    }

    if (data != null) {
      params['data'] = data;
    }

    _sendNotification('logging', params);
  }

  /// Disconnect the server from its transport
  void disconnect() {
    if (_transport != null) {
      _transport!.close();
      _onDisconnect();
    }
  }

  /// Handle transport disconnection
  void _onDisconnect() {
    _transport = null;
  }

  /// Handle incoming messages from the transport
  void _handleMessage(dynamic rawMessage) {
    try {
      final message = JsonRpcMessage.fromJson(
        rawMessage is String ? jsonDecode(rawMessage) : rawMessage,
      );
      _messageController.add(message);
    } catch (e) {
      _sendErrorResponse(null, -32700, 'Parse error: $e');
    }
  }

  /// Process a JSON-RPC message
  Future<void> _processMessage(JsonRpcMessage message) async {
    try {
      if (message.isNotification) {
        await _handleNotification(message);
      } else if (message.isRequest) {
        await _handleRequest(message);
      } else {
        _sendErrorResponse(message.id, -32600, 'Invalid request');
      }
    } catch (e, stackTrace) {
      stderr.writeln('Error processing message: $e');
      stderr.writeln('Stacktrace: $stackTrace');

      _sendErrorResponse(
          message.id,
          -32000,
          'Internal server error: ${e.toString()}'
      );
    }
  }


// Handle a JSON-RPC notification
  Future<void> _handleNotification(JsonRpcMessage notification) async {
    stderr.writeln('[Flutter MCP] Received notification: ${notification.method}');

    // Handle client notifications
    switch (notification.method) {
      case 'initialized':
      case 'notifications/initialized':
        stderr.writeln('[Flutter MCP] Client initialized notification received');
        sendLog(LogLevel.info, 'Client initialized successfully');
        break;
      case 'client/ready':
        stderr.writeln('[Flutter MCP] Client ready notification received');
        break;
      default:
        stderr.writeln('[Flutter MCP] Unknown notification: ${notification.method}');
        break;
    }
  }

  /// Handle a JSON-RPC request
  Future<void> _handleRequest(JsonRpcMessage request) async {
    switch (request.method) {
      case 'initialize':
        await _handleInitialize(request);
        break;
      case 'tools/list':
        await _handleToolsList(request);
        break;
      case 'tools/call':
        await _handleToolCall(request);
        break;
      case 'resources/list':
        await _handleResourcesList(request);
        break;
      case 'resources/read':
        await _handleResourceRead(request);
        break;
      case 'prompts/list':
        await _handlePromptsList(request);
        break;
      case 'prompts/get':
        await _handlePromptGet(request);
        break;
      default:
        _sendErrorResponse(request.id, -32601, 'Method not found');
    }
  }

  /// Handle initialize request
  Future<void> _handleInitialize(JsonRpcMessage request) async {
    ClientCapabilities.fromJson(
        request.params?['capabilities'] ?? {});

    final response = {
      'protocolVersion': protocolVersion,
      'serverInfo': {
        'name': name,
        'version': version
      },
      'capabilities': capabilities.toJson(),
    };

    _sendResponse(request.id, response);
  }

  /// Handle tools/list request
  Future<void> _handleToolsList(JsonRpcMessage request) async {
    stderr.writeln('Tools listing requested');
    stderr.writeln('Current tools: ${_tools.length}');

    if (!capabilities.tools) {
      stderr.writeln('Tools capability not supported');
      _sendErrorResponse(request.id, -32601, 'Tools capability not supported');
      return;
    }

    try {
      final toolsList = _tools.values.map((tool) {
        stderr.writeln('Processing tool: ${tool.name}');
        stderr.writeln('Tool input schema: ${tool.inputSchema}');
        return tool.toJson();
      }).toList();

      stderr.writeln('Sending tools list: $toolsList');
      _sendResponse(request.id, {'tools': toolsList});
    } catch (e, stackTrace) {
      stderr.writeln('Error in tools list: $e');
      stderr.writeln('Stacktrace: $stackTrace');
      _sendErrorResponse(request.id, -32000, 'Internal server error processing tools');
    }
  }

  /// Handle tools/call request
  Future<void> _handleToolCall(JsonRpcMessage request) async {
    if (!capabilities.tools) {
      _sendErrorResponse(request.id, -32601, 'Tools capability not supported');
      return;
    }

    final toolName = request.params?['name'];
    if (toolName == null || !_tools.containsKey(toolName)) {
      _sendErrorResponse(request.id, -32602, 'Tool not found: $toolName');
      return;
    }

    final handler = _toolHandlers[toolName]!;
    final arguments = request.params?['arguments'] ?? {};

    try {
      final result = await handler(arguments);
      _sendResponse(request.id, result.toJson());
    } catch (e) {
      _sendErrorResponse(request.id, -32000, 'Tool execution error: $e');
    }
  }

  /// Handle resources/list request
  Future<void> _handleResourcesList(JsonRpcMessage request) async {
    if (!capabilities.resources) {
      _sendErrorResponse(request.id, -32601, 'Resources capability not supported');
      return;
    }

    final resourcesList = _resources.values.map((resource) => {
      'uri': resource.uri,
      'name': resource.name,
      'description': resource.description,
      'mime_type': resource.mimeType,
      if (resource.uriTemplate != null) 'uri_template': resource.uriTemplate,
    }).toList();

    _sendResponse(request.id, {'resources': resourcesList});
  }

  /// Handle resources/read request
  Future<void> _handleResourceRead(JsonRpcMessage request) async {
    if (!capabilities.resources) {
      _sendErrorResponse(request.id, -32601, 'Resources capability not supported');
      return;
    }

    final uri = request.params?['uri'];
    if (uri == null) {
      _sendErrorResponse(request.id, -32602, 'URI parameter is required');
      return;
    }

    ResourceHandler? handler;
    for (final entry in _resources.entries) {
      if (entry.key == uri || _uriMatches(uri, entry.key, entry.value.uriTemplate)) {
        handler = _resourceHandlers[entry.key];
        break;
      }
    }

    if (handler == null) {
      _sendErrorResponse(request.id, -32602, 'Resource not found: $uri');
      return;
    }

    try {
      final result = await handler(uri, request.params ?? {});
      _sendResponse(request.id, result.toJson());
    } catch (e) {
      _sendErrorResponse(request.id, -32000, 'Resource read error: $e');
    }
  }


  /// Handle prompts/list request
  Future<void> _handlePromptsList(JsonRpcMessage request) async {
    if (!capabilities.prompts) {
      _sendErrorResponse(request.id, -32601, 'Prompts capability not supported');
      return;
    }

    final promptsList = _prompts.values.map((prompt) => prompt.toJson()).toList();
    _sendResponse(request.id, {'prompts': promptsList});
  }

  /// Handle prompts/get request
  Future<void> _handlePromptGet(JsonRpcMessage request) async {
    if (!capabilities.prompts) {
      _sendErrorResponse(request.id, -32601, 'Prompts capability not supported');
      return;
    }

    final promptName = request.params?['name'];
    if (promptName == null || !_prompts.containsKey(promptName)) {
      _sendErrorResponse(request.id, -32602, 'Prompt not found: $promptName');
      return;
    }

    final handler = _promptHandlers[promptName]!;
    final arguments = request.params?['arguments'] ?? {};

    try {
      final result = await handler(arguments);
      _sendResponse(request.id, result.toJson());
    } catch (e) {
      _sendErrorResponse(request.id, -32000, 'Prompt execution error: $e');
    }
  }

  /// Check if a URI matches a template pattern
  bool _uriMatches(String uri, String pattern, Map<String, dynamic>? template) {
    if (pattern == uri) return true;
    if (template == null) return false;

    // Simple template matching - could be enhanced for more complex patterns
    final patternParts = pattern.split('/');
    final uriParts = uri.split('/');

    if (patternParts.length != uriParts.length) return false;

    for (var i = 0; i < patternParts.length; i++) {
      final patternPart = patternParts[i];
      final uriPart = uriParts[i];

      if (patternPart.startsWith('{') && patternPart.endsWith('}')) {
        // This is a template parameter
        continue;
      } else if (patternPart != uriPart) {
        return false;
      }
    }

    return true;
  }

  /// Send a JSON-RPC response
  void _sendResponse(dynamic id, dynamic result) {
    if (_transport == null) return;

    final response = {
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    };

    _transport!.send(response);
  }

  /// Send a JSON-RPC error response
  void _sendErrorResponse(dynamic id, int code, String message) {
    if (_transport == null) return;

    final response = {
      'jsonrpc': '2.0',
      'id': id,
      'error': {
        'code': code,
        'message': message,
      },
    };

    _transport!.send(response);
  }

  /// Send a JSON-RPC notification
  void _sendNotification(String method, Map<String, dynamic> params) {
    if (_transport == null) return;

    final notification = {
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    };

    _transport!.send(notification);
  }
}

/// Server capabilities configuration
class ServerCapabilities {
  /// Tool support
  final bool tools;

  /// Whether tools list changes are sent as notifications
  final bool toolsListChanged;

  /// Resource support
  final bool resources;

  /// Whether resources list changes are sent as notifications
  final bool resourcesListChanged;

  /// Prompt support
  final bool prompts;

  /// Whether prompts list changes are sent as notifications
  final bool promptsListChanged;

  /// Create a capabilities object with specified settings
  const ServerCapabilities({
    this.tools = false,
    this.toolsListChanged = false,
    this.resources = false,
    this.resourcesListChanged = false,
    this.prompts = false,
    this.promptsListChanged = false,
  });

  /// Convert capabilities to JSON
  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{};

    if (tools) {
      result['tools'] = {'listChanged': toolsListChanged};
    }

    if (resources) {
      result['resources'] = {'listChanged': resourcesListChanged};
    }

    if (prompts) {
      result['prompts'] = {'listChanged': promptsListChanged};
    }

    return result;
  }
}

/// Client capabilities
class ClientCapabilities {
  /// Root management support
  final bool roots;

  /// Whether roots list changes are sent as notifications
  final bool rootsListChanged;

  /// Client capabilities from JSON
  factory ClientCapabilities.fromJson(Map<String, dynamic> json) {
    final rootsData = json['roots'] as Map<String, dynamic>?;

    return ClientCapabilities(
      roots: rootsData != null,
      rootsListChanged: rootsData?['listChanged'] == true,
    );
  }

  /// Create client capabilities object
  const ClientCapabilities({
    this.roots = false,
    this.rootsListChanged = false,
  });
}

/// Error class for MCP-related errors
class McpError implements Exception {
  final String message;

  McpError(this.message);

  @override
  String toString() => 'McpError: $message';
}

/// JSON-RPC message
class JsonRpcMessage {
  final String jsonrpc;
  final dynamic id;
  final String? method;
  final Map<String, dynamic>? params;
  final dynamic result;
  final Map<String, dynamic>? error;

  bool get isNotification => id == null && method != null;
  bool get isRequest => id != null && method != null;
  bool get isResponse => id != null && (result != null || error != null);

  JsonRpcMessage({
    required this.jsonrpc,
    this.id,
    this.method,
    this.params,
    this.result,
    this.error,
  });

  factory JsonRpcMessage.fromJson(Map<String, dynamic> json) {
    return JsonRpcMessage(
      jsonrpc: json['jsonrpc'],
      id: json['id'],
      method: json['method'],
      params: json['params'] != null ? Map<String, dynamic>.from(json['params']) : null,
      result: json['result'],
      error: json['error'] != null ? Map<String, dynamic>.from(json['error']) : null,
    );
  }
}

/// Logging levels for MCP
enum LogLevel {
  debug,
  info,
  notice,
  warning,
  error,
  critical,
  alert,
  emergency
}

/// Type definition for tool handler functions
typedef ToolHandler = Future<CallToolResult> Function(Map<String, dynamic> arguments);

/// Type definition for resource handler functions
typedef ResourceHandler = Future<ReadResourceResult> Function(String uri, Map<String, dynamic> params);

/// Type definition for prompt handler functions
typedef PromptHandler = Future<GetPromptResult> Function(Map<String, dynamic> arguments);