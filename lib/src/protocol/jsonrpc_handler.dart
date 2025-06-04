import 'dart:async';
import 'dart:convert';
import 'package:meta/meta.dart';
import 'package:logging/logging.dart';

import 'protocol.dart';
import '../common/result.dart';
import '../server/server.dart';

final _logger = Logger('jsonrpc_handler');

/// JSON-RPC 2.0 compliant message handler for MCP protocol
class JsonRpcHandler {
  /// Registered method handlers
  final Map<String, Future<dynamic> Function(Map<String, dynamic>)> _methodHandlers = {};
  
  /// Protocol version negotiated with client
  String? _negotiatedVersion;
  
  /// Server capabilities
  ServerCapabilities? _capabilities;
  
  /// Whether the handler has been initialized
  bool _initialized = false;

  /// Register a method handler
  void registerMethod(String method, Future<dynamic> Function(Map<String, dynamic>) handler) {
    // Register method without validation for flexibility
    _methodHandlers[method] = handler;
  }

  /// Handle incoming JSON-RPC message
  Future<String?> handleMessage(String rawMessage) async {
    try {
      final json = jsonDecode(rawMessage) as Map<String, dynamic>;
      final message = JsonRpcMessage.fromJson(json);
      
      return await _processMessage(message);
    } catch (e, stackTrace) {
      _logger.severe('Error parsing message: $e', e, stackTrace);
      return _createErrorResponse(
        null,
        McpErrorCodes.parseError,
        'Parse error: $e',
      );
    }
  }

  /// Process a parsed JSON-RPC message
  Future<String?> _processMessage(JsonRpcMessage message) async {
    switch (message.type) {
      case JsonRpcMessageType.request:
        return await _handleRequest(message as JsonRpcRequest);
      case JsonRpcMessageType.response:
        await _handleResponse(message as JsonRpcResponse);
        return null;
      case JsonRpcMessageType.notification:
        _handleNotification(message as JsonRpcNotification);
        return null;
    }
  }

  /// Handle JSON-RPC request
  Future<String> _handleRequest(JsonRpcRequest request) async {
    try {
      // Special handling for initialize method
      if (request.method == McpMethods.initialize) {
        return await _handleInitialize(request);
      }

      // Check if initialized (except for initialize method)
      if (!_initialized) {
        return _createErrorResponse(
          request.id,
          McpErrorCodes.protocolError,
          'Server not initialized. Call initialize first.',
        );
      }

      // Check if method is supported
      final handler = _methodHandlers[request.method];
      if (handler == null) {
        return _createErrorResponse(
          request.id,
          McpErrorCodes.methodNotFound,
          'Method not found: ${request.method}',
        );
      }

      // Validate parameters based on protocol version
      final validationResult = _validateParams(request.method, request.params);
      if (validationResult.isFailure) {
        return _createErrorResponse(
          request.id,
          McpErrorCodes.invalidParams,
          validationResult.failureOrNull.toString(),
        );
      }

      // Execute handler
      final result = await handler(request.params ?? {});
      
      return _createSuccessResponse(request.id, result);
    } catch (e, stackTrace) {
      _logger.severe('Error handling request ${request.method}: $e', e, stackTrace);
      return _createErrorResponse(
        request.id,
        McpErrorCodes.internalError,
        'Internal error: $e',
      );
    }
  }

  /// Handle initialize method
  Future<String> _handleInitialize(JsonRpcRequest request) async {
    try {
      final params = request.params ?? {};
      final clientInfo = params['clientInfo'] as Map<String, dynamic>?;
      // Note: clientCapabilities are stored but not used in current implementation  
      final clientProtocolVersion = params['protocolVersion'] as String?;

      // Validate required parameters
      if (clientInfo == null) {
        return _createErrorResponse(
          request.id,
          McpErrorCodes.invalidParams,
          'Missing required parameter: clientInfo',
        );
      }

      if (clientProtocolVersion == null) {
        return _createErrorResponse(
          request.id,
          McpErrorCodes.invalidParams,
          'Missing required parameter: protocolVersion',
        );
      }

      // Negotiate protocol version
      final negotiatedVersion = McpProtocol.negotiate(
        [clientProtocolVersion],
        McpProtocol.supportedVersions,
      );

      if (negotiatedVersion == null) {
        return _createErrorResponse(
          request.id,
          McpErrorCodes.protocolError,
          'Unsupported protocol version: $clientProtocolVersion. '
          'Supported versions: ${McpProtocol.supportedVersions.join(', ')}',
        );
      }

      _negotiatedVersion = negotiatedVersion;
      _initialized = true;

      // Set default capabilities if not provided
      _capabilities ??= const ServerCapabilities(
        tools: true,
        toolsListChanged: true,
        resources: true,
        resourcesListChanged: true,
        prompts: true,
        promptsListChanged: true,
        sampling: true,
      );

      final response = {
        'protocolVersion': negotiatedVersion,
        'capabilities': _capabilities!.toJson(),
        'serverInfo': {
          'name': 'MCP Dart Server',
          'version': '1.0.0',
        },
      };

      _logger.info('Initialized with protocol version: $negotiatedVersion');
      return _createSuccessResponse(request.id, response);
    } catch (e, stackTrace) {
      _logger.severe('Error in initialize: $e', e, stackTrace);
      return _createErrorResponse(
        request.id,
        McpErrorCodes.internalError,
        'Initialization failed: $e',
      );
    }
  }

  /// Handle JSON-RPC response (for bidirectional communication)
  Future<void> _handleResponse(JsonRpcResponse response) async {
    // Handle responses to requests we sent to the client
    _logger.fine('Received response: ${response.id}');
  }

  /// Handle JSON-RPC notification
  Future<String?> _handleNotification(JsonRpcNotification notification) async {
    _logger.fine('Received notification: ${notification.method}');
    
    final handler = _methodHandlers[notification.method];
    if (handler != null) {
      try {
        await handler(notification.params ?? {});
      } catch (e, stackTrace) {
        _logger.severe('Error handling notification ${notification.method}: $e', e, stackTrace);
      }
    }
    return null;
  }

  /// Validate request parameters based on method and protocol version
  Result<void, String> _validateParams(String method, Map<String, dynamic>? params) {
    // Basic validation - can be extended based on specific method requirements
    switch (method) {
      case McpMethods.callTool:
        if (params == null || params['name'] == null) {
          return const Result.failure('callTool requires name parameter');
        }
        break;
      case McpMethods.readResource:
        if (params == null || params['uri'] == null) {
          return const Result.failure('readResource requires uri parameter');
        }
        break;
      case McpMethods.getPrompt:
        if (params == null || params['name'] == null) {
          return const Result.failure('getPrompt requires name parameter');
        }
        break;
    }
    
    return const Result.success(null);
  }

  /// Create JSON-RPC success response
  String _createSuccessResponse(dynamic id, dynamic result) {
    final response = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    };
    return jsonEncode(response);
  }

  /// Create JSON-RPC error response
  String _createErrorResponse(dynamic id, int code, String message, [dynamic data]) {
    final error = <String, dynamic>{
      'code': code,
      'message': message,
    };
    if (data != null) {
      error['data'] = data;
    }

    final response = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'error': error,
    };
    return jsonEncode(response);
  }

  /// Send notification to client
  String createNotification(String method, Map<String, dynamic>? params) {
    final notification = <String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
    };
    if (params != null) {
      notification['params'] = params;
    }
    return jsonEncode(notification);
  }

  /// Set server capabilities
  void setCapabilities(ServerCapabilities capabilities) {
    _capabilities = capabilities;
  }

  /// Get negotiated protocol version
  String? get protocolVersion => _negotiatedVersion;

  /// Check if handler is initialized
  bool get isInitialized => _initialized;
}

/// JSON-RPC message types
enum JsonRpcMessageType { request, response, notification }

/// Base JSON-RPC message
@immutable
sealed class JsonRpcMessage {
  final String jsonrpc;
  
  const JsonRpcMessage({required this.jsonrpc});
  
  JsonRpcMessageType get type;
  
  factory JsonRpcMessage.fromJson(Map<String, dynamic> json) {
    final jsonrpc = json['jsonrpc'] as String?;
    if (jsonrpc != '2.0') {
      throw ArgumentError('Invalid JSON-RPC version: $jsonrpc');
    }

    if (json.containsKey('method')) {
      if (json.containsKey('id')) {
        return JsonRpcRequest.fromJson(json);
      } else {
        return JsonRpcNotification.fromJson(json);
      }
    } else if (json.containsKey('result') || json.containsKey('error')) {
      return JsonRpcResponse.fromJson(json);
    } else {
      throw ArgumentError('Invalid JSON-RPC message structure');
    }
  }
}

/// JSON-RPC request
@immutable
class JsonRpcRequest extends JsonRpcMessage {
  final dynamic id;
  final String method;
  final Map<String, dynamic>? params;

  const JsonRpcRequest({
    required super.jsonrpc,
    required this.id,
    required this.method,
    this.params,
  });

  @override
  JsonRpcMessageType get type => JsonRpcMessageType.request;

  factory JsonRpcRequest.fromJson(Map<String, dynamic> json) {
    return JsonRpcRequest(
      jsonrpc: json['jsonrpc'],
      id: json['id'],
      method: json['method'],
      params: json['params'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'jsonrpc': jsonrpc,
      'id': id,
      'method': method,
    };
    if (params != null) {
      json['params'] = params!;
    }
    return json;
  }
}

/// JSON-RPC response
@immutable
class JsonRpcResponse extends JsonRpcMessage {
  final dynamic id;
  final dynamic result;
  final JsonRpcError? error;

  const JsonRpcResponse({
    required super.jsonrpc,
    required this.id,
    this.result,
    this.error,
  });

  @override
  JsonRpcMessageType get type => JsonRpcMessageType.response;

  factory JsonRpcResponse.fromJson(Map<String, dynamic> json) {
    return JsonRpcResponse(
      jsonrpc: json['jsonrpc'],
      id: json['id'],
      result: json['result'],
      error: json['error'] != null ? JsonRpcError.fromJson(json['error']) : null,
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'jsonrpc': jsonrpc,
      'id': id,
    };
    if (error != null) {
      json['error'] = error!.toJson();
    } else {
      json['result'] = result;
    }
    return json;
  }
}

/// JSON-RPC notification
@immutable
class JsonRpcNotification extends JsonRpcMessage {
  final String method;
  final Map<String, dynamic>? params;

  const JsonRpcNotification({
    required super.jsonrpc,
    required this.method,
    this.params,
  });

  @override
  JsonRpcMessageType get type => JsonRpcMessageType.notification;

  factory JsonRpcNotification.fromJson(Map<String, dynamic> json) {
    return JsonRpcNotification(
      jsonrpc: json['jsonrpc'],
      method: json['method'],
      params: json['params'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'jsonrpc': jsonrpc,
      'method': method,
    };
    if (params != null) {
      json['params'] = params!;
    }
    return json;
  }
}

/// JSON-RPC error
@immutable
class JsonRpcError {
  final int code;
  final String message;
  final dynamic data;

  const JsonRpcError({
    required this.code,
    required this.message,
    this.data,
  });

  factory JsonRpcError.fromJson(Map<String, dynamic> json) {
    return JsonRpcError(
      code: json['code'],
      message: json['message'],
      data: json['data'],
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'code': code,
      'message': message,
    };
    if (data != null) {
      json['data'] = data;
    }
    return json;
  }
}