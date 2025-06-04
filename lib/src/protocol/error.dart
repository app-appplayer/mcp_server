/// MCP 2025-03-26 standard error codes and handling (server-side)
library;

import 'dart:async';
import 'package:meta/meta.dart';

/// JSON-RPC 2.0 and MCP 2025-03-26 standard error codes
enum McpErrorCode {
  // JSON-RPC 2.0 standard error codes
  parseError(-32700, "Parse error"),
  invalidRequest(-32600, "Invalid Request"),
  methodNotFound(-32601, "Method not found"),
  invalidParams(-32602, "Invalid params"),
  internalError(-32603, "Internal error"),
  
  // JSON-RPC 2.0 reserved error code range
  serverError(-32000, "Server error"),
  
  // MCP 2025-03-26 specific error codes
  resourceNotFound(-32100, "Resource not found"),
  toolNotFound(-32101, "Tool not found"),
  promptNotFound(-32102, "Prompt not found"),
  incompatibleVersion(-32103, "Incompatible protocol version"),
  unauthorized(-32104, "Unauthorized"),
  operationCancelled(-32105, "Operation cancelled"),
  rateLimited(-32106, "Rate limited"),
  
  // Additional MCP error codes
  resourceUnavailable(-32107, "Resource unavailable"),
  toolExecutionError(-32108, "Tool execution error"),
  promptExecutionError(-32109, "Prompt execution error"),
  sessionExpired(-32110, "Session expired"),
  quotaExceeded(-32111, "Quota exceeded"),
  validationError(-32112, "Validation error"),
  conflictError(-32113, "Conflict error"),
  dependencyError(-32114, "Dependency error"),
  timeoutError(-32115, "Timeout error"),
  
  // Authentication related errors
  authenticationRequired(-32120, "Authentication required"),
  authenticationFailed(-32121, "Authentication failed"),
  insufficientPermissions(-32122, "Insufficient permissions"),
  tokenExpired(-32123, "Token expired"),
  tokenInvalid(-32124, "Token invalid"),
  
  // Transport related errors
  connectionLost(-32130, "Connection lost"),
  connectionTimeout(-32131, "Connection timeout"),
  protocolError(-32132, "Protocol error"),
  encodingError(-32133, "Encoding error"),
  compressionError(-32134, "Compression error"),
  
  // Resource related errors
  resourceLocked(-32140, "Resource locked"),
  resourceCorrupted(-32141, "Resource corrupted"),
  resourceTooLarge(-32142, "Resource too large"),
  resourceAccessDenied(-32143, "Resource access denied"),
  
  // Tool related errors
  toolUnavailable(-32150, "Tool unavailable"),
  toolTimeout(-32151, "Tool timeout"),
  toolConfigurationError(-32152, "Tool configuration error"),
  toolDependencyMissing(-32153, "Tool dependency missing"),
  
  // Server specific errors
  serverOverloaded(-32160, "Server overloaded"),
  maintenanceMode(-32161, "Server in maintenance mode"),
  configurationError(-32162, "Server configuration error"),
  storageError(-32163, "Storage error");
  
  const McpErrorCode(this.code, this.message);
  
  final int code;
  final String message;
  
  /// Find enum by error code
  static McpErrorCode? fromCode(int code) {
    for (final errorCode in McpErrorCode.values) {
      if (errorCode.code == code) {
        return errorCode;
      }
    }
    return null;
  }
  
  /// Check error codes by category
  bool get isJsonRpcError => code >= -32768 && code <= -32000;
  bool get isMcpError => code >= -32200 && code <= -32100;
  bool get isAuthError => code >= -32124 && code <= -32120;
  bool get isTransportError => code >= -32134 && code <= -32130;
  bool get isResourceError => code >= -32143 && code <= -32140;
  bool get isToolError => code >= -32153 && code <= -32150;
  bool get isServerError => code >= -32163 && code <= -32160;
  
  /// Check if error is retryable for client
  bool get isRetryable {
    switch (this) {
      case McpErrorCode.rateLimited:
      case McpErrorCode.timeoutError:
      case McpErrorCode.serverOverloaded:
      case McpErrorCode.resourceUnavailable:
      case McpErrorCode.toolUnavailable:
      case McpErrorCode.storageError:
        return true;
      default:
        return false;
    }
  }
  
  /// Check if error is critical
  bool get isCritical {
    switch (this) {
      case McpErrorCode.internalError:
      case McpErrorCode.incompatibleVersion:
      case McpErrorCode.protocolError:
      case McpErrorCode.resourceCorrupted:
      case McpErrorCode.dependencyError:
      case McpErrorCode.configurationError:
        return true;
      default:
        return false;
    }
  }
}

/// MCP server error response
@immutable
class McpServerError implements Exception {
  /// Error code
  final McpErrorCode code;
  
  /// Error message (detailed)
  final String message;
  
  /// Error data (optional)
  final Map<String, dynamic>? data;
  
  /// Request ID (optional)
  final dynamic requestId;
  
  /// Error occurrence time
  final DateTime timestamp;
  
  /// Error trace ID
  final String? traceId;
  
  /// Recommended retry time (seconds)
  final int? retryAfter;
  
  const McpServerError({
    required this.code,
    required this.message,
    this.data,
    this.requestId,
    required this.timestamp,
    this.traceId,
    this.retryAfter,
  });
  
  /// Create with standard error code
  factory McpServerError.standard(
    McpErrorCode code, {
    String? customMessage,
    Map<String, dynamic>? data,
    dynamic requestId,
    String? traceId,
    int? retryAfter,
  }) {
    return McpServerError(
      code: code,
      message: customMessage ?? code.message,
      data: data,
      requestId: requestId,
      timestamp: DateTime.now(),
      traceId: traceId,
      retryAfter: retryAfter,
    );
  }
  
  /// Create Parse Error
  factory McpServerError.parseError({String? details, dynamic requestId}) {
    return McpServerError.standard(
      McpErrorCode.parseError,
      customMessage: details != null 
        ? "Parse error: $details"
        : null,
      requestId: requestId,
    );
  }
  
  /// Create Invalid Request
  factory McpServerError.invalidRequest({String? details, dynamic requestId}) {
    return McpServerError.standard(
      McpErrorCode.invalidRequest,
      customMessage: details != null 
        ? "Invalid request: $details"
        : null,
      requestId: requestId,
    );
  }
  
  /// Create Method Not Found
  factory McpServerError.methodNotFound(String method, {dynamic requestId}) {
    return McpServerError.standard(
      McpErrorCode.methodNotFound,
      customMessage: "Method not found: $method",
      data: {"method": method},
      requestId: requestId,
    );
  }
  
  /// Create Invalid Params
  factory McpServerError.invalidParams({String? details, dynamic requestId}) {
    return McpServerError.standard(
      McpErrorCode.invalidParams,
      customMessage: details != null 
        ? "Invalid params: $details"
        : null,
      requestId: requestId,
    );
  }
  
  /// Create Resource Not Found
  factory McpServerError.resourceNotFound(String uri, {dynamic requestId}) {
    return McpServerError.standard(
      McpErrorCode.resourceNotFound,
      customMessage: "Resource not found: $uri",
      data: {"uri": uri},
      requestId: requestId,
    );
  }
  
  /// Create Tool Not Found
  factory McpServerError.toolNotFound(String toolName, {dynamic requestId}) {
    return McpServerError.standard(
      McpErrorCode.toolNotFound,
      customMessage: "Tool not found: $toolName",
      data: {"tool": toolName},
      requestId: requestId,
    );
  }
  
  /// Create Tool Execution Error
  factory McpServerError.toolExecutionError(
    String toolName, 
    String details, {
    dynamic requestId
  }) {
    return McpServerError.standard(
      McpErrorCode.toolExecutionError,
      customMessage: "Tool execution failed: $toolName - $details",
      data: {"tool": toolName, "details": details},
      requestId: requestId,
    );
  }
  
  /// Create Unauthorized
  factory McpServerError.unauthorized({String? details, dynamic requestId}) {
    return McpServerError.standard(
      McpErrorCode.unauthorized,
      customMessage: details != null 
        ? "Unauthorized: $details"
        : null,
      requestId: requestId,
    );
  }
  
  /// Create Rate Limited
  factory McpServerError.rateLimited({int? retryAfterSeconds, dynamic requestId}) {
    return McpServerError.standard(
      McpErrorCode.rateLimited,
      customMessage: retryAfterSeconds != null 
        ? "Rate limited. Retry after $retryAfterSeconds seconds"
        : null,
      data: retryAfterSeconds != null ? {"retry_after": retryAfterSeconds} : null,
      requestId: requestId,
      retryAfter: retryAfterSeconds,
    );
  }
  
  /// Create Server Overloaded
  factory McpServerError.serverOverloaded({int? retryAfterSeconds, dynamic requestId}) {
    return McpServerError.standard(
      McpErrorCode.serverOverloaded,
      customMessage: "Server overloaded",
      data: retryAfterSeconds != null ? {"retry_after": retryAfterSeconds} : null,
      requestId: requestId,
      retryAfter: retryAfterSeconds,
    );
  }
  
  /// Create Internal Error
  factory McpServerError.internal({String? details, dynamic requestId, String? traceId}) {
    return McpServerError.standard(
      McpErrorCode.internalError,
      customMessage: details != null 
        ? "Internal server error: $details"
        : null,
      requestId: requestId,
      traceId: traceId,
    );
  }
  
  /// Convert to JSON-RPC error response
  Map<String, dynamic> toJsonRpcError() {
    final error = <String, dynamic>{
      "code": code.code,
      "message": message,
    };
    
    // Add extended data
    final combinedData = <String, dynamic>{};
    
    if (data != null) {
      combinedData.addAll(data!);
    }
    
    if (traceId != null) {
      combinedData["trace_id"] = traceId;
    }
    
    if (retryAfter != null) {
      combinedData["retry_after"] = retryAfter;
    }
    
    if (combinedData.isNotEmpty) {
      error["data"] = combinedData;
    }
    
    final response = {
      "jsonrpc": "2.0",
      "error": error,
    };
    
    if (requestId != null) {
      response["id"] = requestId;
    }
    
    return response;
  }
  
  /// Convert to HTTP status code
  int toHttpStatusCode() {
    switch (code) {
      case McpErrorCode.parseError:
      case McpErrorCode.invalidRequest:
      case McpErrorCode.invalidParams:
      case McpErrorCode.validationError:
        return 400; // Bad Request
      
      case McpErrorCode.unauthorized:
      case McpErrorCode.authenticationRequired:
      case McpErrorCode.authenticationFailed:
      case McpErrorCode.tokenExpired:
      case McpErrorCode.tokenInvalid:
        return 401; // Unauthorized
      
      case McpErrorCode.insufficientPermissions:
      case McpErrorCode.resourceAccessDenied:
        return 403; // Forbidden
      
      case McpErrorCode.methodNotFound:
      case McpErrorCode.resourceNotFound:
      case McpErrorCode.toolNotFound:
      case McpErrorCode.promptNotFound:
        return 404; // Not Found
      
      case McpErrorCode.conflictError:
      case McpErrorCode.resourceLocked:
        return 409; // Conflict
      
      case McpErrorCode.resourceTooLarge:
        return 413; // Payload Too Large
      
      case McpErrorCode.incompatibleVersion:
        return 422; // Unprocessable Entity
      
      case McpErrorCode.rateLimited:
      case McpErrorCode.quotaExceeded:
        return 429; // Too Many Requests
      
      case McpErrorCode.internalError:
      case McpErrorCode.serverError:
      case McpErrorCode.configurationError:
      case McpErrorCode.dependencyError:
        return 500; // Internal Server Error
      
      case McpErrorCode.toolUnavailable:
      case McpErrorCode.resourceUnavailable:
      case McpErrorCode.maintenanceMode:
        return 503; // Service Unavailable
      
      case McpErrorCode.timeoutError:
      case McpErrorCode.connectionTimeout:
        return 504; // Gateway Timeout
      
      default:
        return 500; // Internal Server Error
    }
  }
  
  /// Convert to JSON (for logging/debugging)
  Map<String, dynamic> toJson() {
    return {
      "code": code.code,
      "codeName": code.name,
      "message": message,
      if (data != null) "data": data,
      if (requestId != null) "requestId": requestId,
      "timestamp": timestamp.toIso8601String(),
      if (traceId != null) "traceId": traceId,
      if (retryAfter != null) "retryAfter": retryAfter,
      "httpStatus": toHttpStatusCode(),
    };
  }
  
  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.write('McpServerError(${code.name}[${code.code}]: $message');
    
    if (data != null) {
      buffer.write(', data: $data');
    }
    
    if (requestId != null) {
      buffer.write(', requestId: $requestId');
    }
    
    if (retryAfter != null) {
      buffer.write(', retryAfter: ${retryAfter}s');
    }
    
    buffer.write(')');
    return buffer.toString();
  }
  
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is McpServerError &&
        other.code == code &&
        other.message == message &&
        other.requestId == requestId;
  }
  
  @override
  int get hashCode {
    return Object.hash(code, message, requestId);
  }
}

/// Server error handling utilities
class McpServerErrorHandler {
  /// Convert exception to MCP server error
  static McpServerError fromException(
    dynamic exception, {
    McpErrorCode? fallbackCode,
    dynamic requestId,
    String? traceId,
  }) {
    if (exception is McpServerError) {
      return exception;
    }
    
    if (exception is TimeoutException) {
      return McpServerError.standard(
        McpErrorCode.timeoutError,
        customMessage: "Operation timed out: ${exception.message}",
        requestId: requestId,
        traceId: traceId,
      );
    }
    
    if (exception is FormatException) {
      return McpServerError.parseError(
        details: exception.message,
        requestId: requestId,
      );
    }
    
    if (exception is ArgumentError) {
      return McpServerError.invalidParams(
        details: exception.message,
        requestId: requestId,
      );
    }
    
    // Default internal error
    return McpServerError.internal(
      details: exception.toString(),
      requestId: requestId,
      traceId: traceId,
    );
  }
  
  /// Method validation
  static McpServerError? validateMethod(String? method, {dynamic requestId}) {
    if (method == null || method.isEmpty) {
      return McpServerError.invalidRequest(
        details: "Missing method",
        requestId: requestId,
      );
    }
    
    // MCP standard method validation
    if (!_isValidMcpMethod(method)) {
      return McpServerError.methodNotFound(method, requestId: requestId);
    }
    
    return null;
  }
  
  /// Parameter validation
  static McpServerError? validateParams(
    dynamic params, 
    Map<String, bool> requiredFields, {
    dynamic requestId
  }) {
    if (params == null || params is! Map<String, dynamic>) {
      if (requiredFields.isNotEmpty) {
        return McpServerError.invalidParams(
          details: "Missing required parameters",
          requestId: requestId,
        );
      }
      return null;
    }
    
    for (final entry in requiredFields.entries) {
      final field = entry.key;
      final required = entry.value;
      
      if (required && !params.containsKey(field)) {
        return McpServerError.invalidParams(
          details: "Missing required parameter: $field",
          requestId: requestId,
        );
      }
    }
    
    return null;
  }
  
  /// Authentication validation
  static McpServerError? validateAuth(
    Map<String, dynamic>? authContext, 
    List<String> requiredScopes, {
    dynamic requestId
  }) {
    if (authContext == null) {
      return McpServerError.unauthorized(
        details: "Authentication required",
        requestId: requestId,
      );
    }
    
    final userScopes = authContext['scopes'] as List<String>? ?? [];
    final missingScopes = requiredScopes.where((scope) => !userScopes.contains(scope)).toList();
    
    if (missingScopes.isNotEmpty) {
      return McpServerError.standard(
        McpErrorCode.insufficientPermissions,
        customMessage: "Missing required scopes: ${missingScopes.join(', ')}",
        data: {"required_scopes": requiredScopes, "user_scopes": userScopes},
        requestId: requestId,
      );
    }
    
    return null;
  }
  
  /// Resource existence validation
  static McpServerError? validateResourceExists(
    String uri, 
    bool exists, {
    dynamic requestId
  }) {
    if (!exists) {
      return McpServerError.resourceNotFound(uri, requestId: requestId);
    }
    return null;
  }
  
  /// Tool existence validation
  static McpServerError? validateToolExists(
    String toolName, 
    bool exists, {
    dynamic requestId
  }) {
    if (!exists) {
      return McpServerError.toolNotFound(toolName, requestId: requestId);
    }
    return null;
  }
  
  static bool _isValidMcpMethod(String method) {
    const validMethods = {
      'initialize',
      'tools/list',
      'tools/call',
      'resources/list',
      'resources/read',
      'resources/subscribe',
      'resources/unsubscribe',
      'prompts/list',
      'prompts/get',
      'completion/complete',
      'logging/setLevel',
      'notifications/initialized',
      'notifications/cancelled',
      'notifications/progress',
      'notifications/resources/list_changed',
      'notifications/resources/updated',
      'notifications/tools/list_changed',
      'notifications/prompts/list_changed',
    };
    
    return validMethods.contains(method);
  }
}

/// Error severity
enum ErrorSeverity {
  info,
  warning,
  error,
  critical,
}

/// Server error context
@immutable
class ServerErrorContext {
  final String operation;
  final String? userId;
  final String? sessionId;
  final String? clientInfo;
  final Map<String, dynamic>? metadata;
  final DateTime timestamp;
  
  const ServerErrorContext({
    required this.operation,
    this.userId,
    this.sessionId,
    this.clientInfo,
    this.metadata,
    required this.timestamp,
  });
  
  Map<String, dynamic> toJson() => {
    "operation": operation,
    if (userId != null) "userId": userId,
    if (sessionId != null) "sessionId": sessionId,
    if (clientInfo != null) "clientInfo": clientInfo,
    if (metadata != null) "metadata": metadata,
    "timestamp": timestamp.toIso8601String(),
  };
}