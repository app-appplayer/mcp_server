import 'package:meta/meta.dart';

/// MCP Protocol Version constants and definitions
@immutable
class McpProtocol {
  // JSON-RPC version
  static const String jsonRpcVersion = "2.0";
  
  // Protocol versions
  static const String v2024_11_05 = "2024-11-05";
  static const String v2025_03_26 = "2025-03-26";
  static const String latest = v2025_03_26;
  
  /// All supported versions in order of preference (newest first)
  static const List<String> supportedVersions = [v2025_03_26, v2024_11_05];
  
  // Method names (aliases for compatibility)
  static const String methodInitialize = 'initialize';
  static const String methodInitialized = 'notifications/initialized';
  static const String methodListTools = 'tools/list';
  static const String methodCallTool = 'tools/call';
  static const String methodListResources = 'resources/list';
  static const String methodReadResource = 'resources/read';
  static const String methodListPrompts = 'prompts/list';
  static const String methodGetPrompt = 'prompts/get';
  static const String methodComplete = 'completion/complete';
  
  // Error codes (aliases)
  static const int errorMethodNotFound = -32601;
  
  /// Check if a version is supported
  static bool isSupported(String version) => supportedVersions.contains(version);
  
  /// Get the highest compatible version between client and server
  static String? negotiate(List<String> clientVersions, List<String> serverVersions) {
    for (final serverVersion in serverVersions) {
      if (clientVersions.contains(serverVersion)) {
        return serverVersion;
      }
    }
    return null;
  }
}

/// Standard MCP methods that must be implemented
@immutable
class McpMethods {
  // Core protocol methods
  static const String initialize = 'initialize';
  static const String ping = 'ping';
  static const String shutdown = 'shutdown';
  
  // Tool methods
  static const String listTools = 'tools/list';
  static const String callTool = 'tools/call';
  
  // Resource methods
  static const String listResources = 'resources/list';
  static const String readResource = 'resources/read';
  static const String subscribeResource = 'resources/subscribe';
  static const String unsubscribeResource = 'resources/unsubscribe';
  static const String listResourceTemplates = 'resources/templates/list';
  
  // Prompt methods
  static const String listPrompts = 'prompts/list';
  static const String getPrompt = 'prompts/get';
  
  // Logging methods
  static const String setLoggingLevel = 'logging/setLevel';
  
  // Sampling methods
  static const String createMessage = 'sampling/createMessage';
  
  // Roots methods
  static const String listRoots = 'roots/list';
  
  // Completion methods
  static const String completeArgument = 'completion/complete';
  
  // Notification methods
  static const String notificationCancelled = 'notifications/cancelled';
  static const String notificationProgress = 'notifications/progress';
  static const String notificationResourcesListChanged = 'notifications/resources/list_changed';
  static const String notificationToolsListChanged = 'notifications/tools/list_changed';
  static const String notificationPromptsListChanged = 'notifications/prompts/list_changed';
  static const String notificationRootsListChanged = 'notifications/roots/list_changed';
  static const String notificationMessage = 'notifications/message';
}

/// MCP Error codes as defined in the specification
@immutable
class McpErrorCodes {
  // JSON-RPC 2.0 standard errors
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;
  
  // MCP-specific errors
  static const int toolNotFound = -32000;
  static const int resourceNotFound = -32001;
  static const int promptNotFound = -32002;
  static const int cancelled = -32003;
  static const int timeout = -32004;
  static const int permissionDenied = -32005;
  static const int rateLimited = -32006;
  static const int networkError = -32007;
  static const int protocolError = -32008;
  
  /// Get error message for code
  static String getMessage(int code) {
    return switch (code) {
      parseError => 'Parse error',
      invalidRequest => 'Invalid request',
      methodNotFound => 'Method not found',
      invalidParams => 'Invalid params',
      internalError => 'Internal error',
      toolNotFound => 'Tool not found',
      resourceNotFound => 'Resource not found',
      promptNotFound => 'Prompt not found',
      cancelled => 'Operation cancelled',
      timeout => 'Operation timeout',
      permissionDenied => 'Permission denied',
      rateLimited => 'Rate limited',
      networkError => 'Network error',
      protocolError => 'Protocol error',
      _ => 'Unknown error',
    };
  }
}