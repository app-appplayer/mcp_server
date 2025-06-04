import 'package:meta/meta.dart';
import '../auth/auth_middleware.dart';

/// Base content type enum for MCP
enum MessageRole {
  user,
  assistant,
  system,
}

enum MCPContentType {
  text,
  image,
  resource,
}

/// Log levels for MCP protocol
enum McpLogLevel {
  debug,  // 0
  info,   // 1
  notice, // 2
  warning, // 3
  error,  // 4
  critical, // 5
  alert,  // 6
  emergency // 7
}

/// Base class for all MCP content types (2025-03-26 compliant)
@immutable
abstract class Content {
  const Content();

  Map<String, dynamic> toJson();
  
  factory Content.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    return switch (type) {
      'text' => TextContent.fromJson(json),
      'image' => ImageContent.fromJson(json),
      'resource' => ResourceContent.fromJson(json),
      _ => throw ArgumentError('Unknown content type: $type'),
    };
  }
}

/// Text content representation
@immutable
class TextContent extends Content {
  final String text;
  final Map<String, dynamic>? annotations;

  const TextContent({
    required this.text,
    this.annotations,
  });

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'type': 'text',
      'text': text,
    };
    if (annotations != null) json['annotations'] = annotations!;
    return json;
  }
  
  factory TextContent.fromJson(Map<String, dynamic> json) {
    return TextContent(
      text: json['text'] as String,
      annotations: json['annotations'] as Map<String, dynamic>?,
    );
  }
}

/// Image content representation
@immutable
class ImageContent extends Content {
  final String? url;
  final String? data; // Base64 encoded image for 2025 spec
  final String mimeType;
  final Map<String, dynamic>? annotations;

  const ImageContent({
    this.url,
    this.data,
    required this.mimeType,
    this.annotations,
  }) : assert(url != null || data != null, 'Either url or data must be provided');

  factory ImageContent.fromBase64({
    required String base64Data,
    required String mimeType,
  }) {
    return ImageContent(
      data: base64Data,
      mimeType: mimeType,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'type': 'image',
      'mimeType': mimeType,
    };
    
    // 2025 spec uses 'data' for base64, but maintain 'url' for compatibility
    if (data != null) {
      json['data'] = data!;
    } else if (url != null) {
      json['url'] = url!;
    }
    
    if (annotations != null) json['annotations'] = annotations!;
    return json;
  }
  
  factory ImageContent.fromJson(Map<String, dynamic> json) {
    return ImageContent(
      url: json['url'] as String?,
      data: json['data'] as String?,
      mimeType: json['mimeType'] as String,
      annotations: json['annotations'] as Map<String, dynamic>?,
    );
  }
}

/// Resource content representation
@immutable
class ResourceContent extends Content {
  final String uri;
  final String? text;
  final String? blob;
  final String? mimeType;
  final Map<String, dynamic>? annotations;

  const ResourceContent({
    required this.uri,
    this.text,
    this.blob,
    this.mimeType,
    this.annotations,
  });

  @override
  Map<String, dynamic> toJson() {
    final resource = <String, dynamic>{
      'uri': uri,
    };
    if (text != null) resource['text'] = text!;
    if (blob != null) resource['blob'] = blob!;
    if (mimeType != null) resource['mimeType'] = mimeType!;
    
    final json = <String, dynamic>{
      'type': 'resource',
      'resource': resource,
    };
    if (annotations != null) json['annotations'] = annotations!;
    return json;
  }
  
  factory ResourceContent.fromJson(Map<String, dynamic> json) {
    final resource = json['resource'] as Map<String, dynamic>;
    return ResourceContent(
      uri: resource['uri'] as String,
      text: resource['text'] as String?,
      blob: resource['blob'] as String?,
      mimeType: resource['mimeType'] as String?,
      annotations: json['annotations'] as Map<String, dynamic>?,
    );
  }
}

/// Tool definition (2025-03-26 compliant)
@immutable
class Tool {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final bool? supportsProgress;
  final bool? supportsCancellation;
  final Map<String, dynamic>? metadata;

  const Tool({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.supportsProgress,
    this.supportsCancellation,
    this.metadata,
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'name': name,
      'description': description,
      'inputSchema': inputSchema,
    };
    if (supportsProgress == true) json['supportsProgress'] = supportsProgress;
    if (supportsCancellation == true) json['supportsCancellation'] = supportsCancellation;
    if (metadata != null) json['metadata'] = metadata!;
    return json;
  }
  
  factory Tool.fromJson(Map<String, dynamic> json) {
    return Tool(
      name: json['name'] as String,
      description: json['description'] as String,
      inputSchema: json['inputSchema'] as Map<String, dynamic>,
      supportsProgress: json['supportsProgress'] as bool?,
      supportsCancellation: json['supportsCancellation'] as bool?,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Tool call result
class CallToolResult {
  final List<Content> content;
  final bool isStreaming;
  final bool? isError;

  const CallToolResult({
    required this.content,
    this.isStreaming = false,
    this.isError,
  });

  Map<String, dynamic> toJson() {
    return {
      'content': content.map((c) => c.toJson()).toList(),
      'isStreaming': isStreaming,
      if (isError != null) 'isError': isError,
    };
  }
}

/// Resource template definition
class ResourceTemplate {
  final String uriTemplate;
  final String name;
  final String description;
  final String? mimeType;

  const ResourceTemplate({
    required this.uriTemplate,
    required this.name,
    required this.description,
    this.mimeType,
  });

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{
      'uriTemplate': uriTemplate,
      'name': name,
      'description': description,
    };
    if (mimeType != null) {
      result['mimeType'] = mimeType;
    }
    return result;
  }

  factory ResourceTemplate.fromJson(Map<String, dynamic> json) {
    return ResourceTemplate(
      uriTemplate: json['uriTemplate'] as String,
      name: json['name'] as String,
      description: json['description'] as String,
      mimeType: json['mimeType'] as String?,
    );
  }
}

/// Resource definition
class Resource {
  final String uri;
  final String name;
  final String description;
  final String mimeType;
  final Map<String, dynamic>? uriTemplate;

  Resource({
    required this.uri,
    required this.name,
    required this.description,
    required this.mimeType,
    this.uriTemplate,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> result = {};

    result['uri'] = uri;
    result['name'] = name;
    result['description'] = description;
    result['mimeType'] = mimeType;

    if (uriTemplate != null) {
      result['uriTemplate'] = uriTemplate;
    }

    return result;
  }
}

/// Resource content info (used in ReadResourceResult)
class ResourceContentInfo {
  final String uri;
  final String? mimeType;
  final String? text;
  final String? blob;
  
  ResourceContentInfo({
    required this.uri,
    this.mimeType,
    this.text,
    this.blob,
  });
  
  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{'uri': uri};
    if (mimeType != null) result['mimeType'] = mimeType;
    if (text != null) result['text'] = text;
    if (blob != null) result['blob'] = blob;
    return result;
  }
  
  factory ResourceContentInfo.fromJson(Map<String, dynamic> json) {
    return ResourceContentInfo(
      uri: json['uri'] as String,
      mimeType: json['mimeType'] as String?,
      text: json['text'] as String?,
      blob: json['blob'] as String?,
    );
  }
}

/// Resource read result
class ReadResourceResult {
  final List<ResourceContentInfo> contents;

  ReadResourceResult({
    required this.contents,
  });

  Map<String, dynamic> toJson() {
    return {
      'contents': contents.map((c) => c.toJson()).toList(),
    };
  }
  
  factory ReadResourceResult.fromJson(Map<String, dynamic> json) {
    final List<dynamic> contentsList = json['contents'] as List<dynamic>? ?? [];
    final contents = contentsList
        .map((content) => ResourceContentInfo.fromJson(content as Map<String, dynamic>))
        .toList();

    return ReadResourceResult(contents: contents);
  }
}

/// Prompt argument definition
class PromptArgument {
  final String name;
  final String description;
  final bool required;
  final String? defaultValue;

  PromptArgument({
    required this.name,
    required this.description,
    this.required = false,
    this.defaultValue,
  });

  Map<String, dynamic> toJson() {
    final result = {
      'name': name,
      'description': description,
      'required': required,
    };

    if (defaultValue != null) {
      result['default'] = defaultValue as Object;
    }

    return result;
  }
}

/// Prompt definition
class Prompt {
  final String name;
  final String description;
  final List<PromptArgument> arguments;

  Prompt({
    required this.name,
    required this.description,
    required this.arguments,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'description': description,
      'arguments': arguments.map((arg) => arg.toJson()).toList(),
    };
  }
}

/// Message model for prompt system
class Message {
  final String role;
  final Content content;

  Message({
    required this.role,
    required this.content,
  });

  Map<String, dynamic> toJson() {
    return {
      'role': role,
      'content': content.toJson(),
    };
  }
}

/// Get prompt result
class GetPromptResult {
  final String description;
  final List<Message> messages;

  GetPromptResult({
    required this.description,
    required this.messages,
  });

  Map<String, dynamic> toJson() {
    return {
      'description': description,
      'messages': messages.map((m) => m.toJson()).toList(),
    };
  }
}

/// Model hint for sampling
class ModelHint {
  final String name;
  final String? weight;

  ModelHint({
    required this.name,
    this.weight,
  });

  Map<String, dynamic> toJson() {
    final result = {'name': name};
    if (weight != null) {
      result['weight'] = weight!;
    }
    return result;
  }
}

/// Model preferences for sampling
class ModelPreferences {
  final List<ModelHint>? hints;
  final double? intelligencePriority;
  final double? speedPriority;
  final double? costPriority;

  ModelPreferences({
    this.hints,
    this.intelligencePriority,
    this.speedPriority,
    this.costPriority,
  });

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{};

    if (hints != null && hints!.isNotEmpty) {
      result['hints'] = hints!.map((h) => h.toJson()).toList();
    }

    if (intelligencePriority != null) {
      result['intelligencePriority'] = intelligencePriority;
    }

    if (speedPriority != null) {
      result['speedPriority'] = speedPriority;
    }

    if (costPriority != null) {
      result['costPriority'] = costPriority;
    }

    return result;
  }
}

/// Create message request for sampling
class CreateMessageRequest {
  final List<Message> messages;
  final ModelPreferences? modelPreferences;
  final String? systemPrompt;
  final String? includeContext;
  final int? maxTokens;
  final double? temperature;
  final List<String>? stopSequences;
  final Map<String, dynamic>? metadata;

  CreateMessageRequest({
    required this.messages,
    this.modelPreferences,
    this.systemPrompt,
    this.includeContext,
    this.maxTokens,
    this.temperature,
    this.stopSequences,
    this.metadata,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> result = {};

    result['messages'] = messages.map((m) => m.toJson()).toList();

    if (modelPreferences != null) {
      result['modelPreferences'] = modelPreferences!.toJson();
    }

    if (systemPrompt != null) {
      result['systemPrompt'] = systemPrompt;
    }

    if (includeContext != null) {
      result['includeContext'] = includeContext;
    }

    if (maxTokens != null) {
      result['maxTokens'] = maxTokens;
    }

    if (temperature != null) {
      result['temperature'] = temperature;
    }

    if (stopSequences != null) {
      result['stopSequences'] = stopSequences;
    }

    if (metadata != null) {
      result['metadata'] = metadata;
    }

    return result;
  }
}

/// Create message result from sampling
class CreateMessageResult {
  final String model;
  final String? stopReason;
  final String role;
  final Content content;

  CreateMessageResult({
    required this.model,
    this.stopReason,
    required this.role,
    required this.content,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> result = {};

    result['model'] = model;
    result['role'] = role;
    result['content'] = content.toJson();

    if (stopReason != null) {
      result['stopReason'] = stopReason;
    }

    return result;
  }


  factory CreateMessageResult.fromJson(Map<String, dynamic> json) {
    final contentMap = json['content'] as Map<String, dynamic>;
    final contentType = contentMap['type'] as String;

    Content content;
    switch (contentType) {
      case 'text':
        content = TextContent(text: contentMap['text']);
        break;
      case 'image':
        content = ImageContent(
          url: contentMap['url'],
          mimeType: contentMap['mimeType'],
        );
        break;
      case 'resource':
        content = ResourceContent(
            uri: contentMap['uri'],
            text: contentMap['text'],
            blob: contentMap['blob']
        );
        break;
      default:
        throw FormatException('Unknown content type: $contentType');
    }

    return CreateMessageResult(
      model: json['model'],
      stopReason: json['stopReason'],
      role: json['role'],
      content: content,
    );
  }
}

/// Root definition for filesystem access
class Root {
  final String uri;
  final String name;
  final String? description;

  Root({
    required this.uri,
    required this.name,
    this.description,
  });

  Map<String, dynamic> toJson() {
    final result = {
      'uri': uri,
      'name': name,
    };

    if (description != null) {
      result['description'] = description!;
    }

    return result;
  }
}

/// Server health information
class ServerHealth {
  final String status;
  final String? version;
  final bool isRunning;
  final int connectedSessions;
  final int registeredTools;
  final int registeredResources;
  final int registeredPrompts;
  final DateTime startTime;
  final Duration uptime;
  final Map<String, dynamic> metrics;
  final Map<String, dynamic>? capabilities;

  ServerHealth({
    this.status = 'healthy',
    this.version,
    required this.isRunning,
    required this.connectedSessions,
    required this.registeredTools,
    required this.registeredResources,
    required this.registeredPrompts,
    required this.startTime,
    required this.uptime,
    required this.metrics,
    this.capabilities,
  });

  Map<String, dynamic> toJson() {
    return {
      'status': status,
      if (version != null) 'version': version,
      'isRunning': isRunning,
      'connectedSessions': connectedSessions,
      'registeredTools': registeredTools,
      'registeredResources': registeredResources,
      'registeredPrompts': registeredPrompts,
      'startTime': startTime.toIso8601String(),
      'uptimeSeconds': uptime.inSeconds,
      'metrics': metrics,
      if (capabilities != null) 'capabilities': capabilities,
    };
  }
}

/// Cached resource item for performance optimization
class CachedResource {
  final String uri;
  final ReadResourceResult content;
  final DateTime cachedAt;
  final Duration maxAge;

  CachedResource({
    required this.uri,
    required this.content,
    required this.cachedAt,
    required this.maxAge,
  });

  bool get isExpired {
    final now = DateTime.now();
    final expiresAt = cachedAt.add(maxAge);
    return now.isAfter(expiresAt);
  }
}

/// Pending operation for cancellation support
class PendingOperation {
  final String id;
  final String sessionId;
  final String type;
  final DateTime createdAt;
  final String? requestId;
  bool isCancelled = false;

  PendingOperation({
    required this.id,
    required this.sessionId,
    required this.type,
    this.requestId,
  }) : createdAt = DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sessionId': sessionId,
      'type': type,
      'createdAt': createdAt.toIso8601String(),
      'isCancelled': isCancelled,
      if (requestId != null) 'requestId': requestId,
    };
  }
}
/// Error codes for standardized error handling
class ErrorCode {
  // Standard JSON-RPC error codes
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;

  // MCP protocol error codes
  static const int resourceNotFound = -32100;
  static const int toolNotFound = -32101;
  static const int promptNotFound = -32102;
  static const int incompatibleVersion = -32103;
  static const int unauthorized = -32104;
  static const int operationCancelled = -32105;
  static const int rateLimited = -32106;
}

/// Client session information
class ClientSession {
  final String id;
  final DateTime connectedAt;
  final Map<String, dynamic> metadata;
  
  // MCP 2025-03-26 required properties
  bool isInitialized = false;
  String? negotiatedProtocolVersion;
  Map<String, dynamic>? capabilities;
  dynamic transport; // ServerTransport
  List<Map<String, dynamic>> roots = [];
  
  // OAuth 2.1 authentication support (2025-03-26)
  String? authToken;
  Map<String, Map<String, dynamic>>? pendingAuthCodes;
  Map<String, Map<String, dynamic>>? accessTokens;
  AuthContext? authContext;

  ClientSession({
    required this.id,
    required this.connectedAt,
    this.metadata = const {},
    this.transport,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'connectedAt': connectedAt.toIso8601String(),
      'metadata': metadata,
      'isInitialized': isInitialized,
      'negotiatedProtocolVersion': negotiatedProtocolVersion,
      'capabilities': capabilities,
      'roots': roots,
    };
  }
}

/// Progress notification data (2025-03-26)
@immutable
class ProgressNotification {
  final String progressToken;
  final double progress;
  final double? total;

  const ProgressNotification({
    required this.progressToken,
    required this.progress,
    this.total,
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'progressToken': progressToken,
      'progress': progress,
    };
    if (total != null) json['total'] = total!;
    return json;
  }
}

/// Prompt message (2025-03-26)
@immutable
class PromptMessage {
  final PromptMessageRole role;
  final Content content;

  const PromptMessage({
    required this.role,
    required this.content,
  });

  Map<String, dynamic> toJson() {
    return {
      'role': role.name,
      'content': content.toJson(),
    };
  }
}

/// Prompt message roles
enum PromptMessageRole {
  user,
  assistant,
  system;
}

/// Cancellation token for async operations
class CancellationToken {
  bool _isCancelled = false;
  final List<Function()> _callbacks = [];
  
  /// Whether the operation has been cancelled
  bool get isCancelled => _isCancelled;
  
  /// Cancel the operation
  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    
    // Notify all callbacks
    for (final callback in _callbacks) {
      callback();
    }
    _callbacks.clear();
  }
  
  /// Register a callback to be called when cancelled
  void onCancel(Function() callback) {
    if (_isCancelled) {
      // Already cancelled, call immediately
      callback();
    } else {
      _callbacks.add(callback);
    }
  }
  
  /// Remove a callback
  void removeCallback(Function() callback) {
    _callbacks.remove(callback);
  }
  
  /// Check if cancelled and throw if so
  void throwIfCancelled() {
    if (_isCancelled) {
      throw CancelledException('Operation was cancelled');
    }
  }
}

/// Exception thrown when an operation is cancelled
class CancelledException implements Exception {
  final String message;
  
  CancelledException([this.message = 'Operation cancelled']);
  
  @override
  String toString() => 'CancelledException: $message';
}

/// Batch request tracker for handling JSON-RPC batch requests
class BatchRequestTracker {
  final String batchId;
  final int totalRequests;
  final List<Map<String, dynamic>> responses = [];
  final Set<dynamic> processedIds = {};
  final DateTime createdAt = DateTime.now();
  
  BatchRequestTracker({
    required this.batchId,
    required this.totalRequests,
  });
  
  /// Add a response to the batch
  void addResponse(dynamic id, Map<String, dynamic> response) {
    if (id != null && !processedIds.contains(id)) {
      processedIds.add(id);
      responses.add(response);
    }
  }
  
  /// Check if all requests have been processed
  bool get isComplete => responses.length >= totalRequests;
  
  /// Get the batch response (array of responses)
  List<Map<String, dynamic>> getBatchResponse() => List.unmodifiable(responses);
}