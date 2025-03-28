import '../../mcp_server.dart';

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

/// Base class for all MCP content types
abstract class Content {
  final MCPContentType type;

  Content(this.type);

  Map<String, dynamic> toJson();
}

/// Text content representation
class TextContent extends Content {
  final String text;

  TextContent({required this.text}) : super(MCPContentType.text);

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'text',
      'text': text,
    };
  }
}

/// Image content representation
class ImageContent extends Content {
  final String url;
  final String? base64Data;
  final String mimeType;

  ImageContent({
    required this.url,
    this.base64Data,
    required this.mimeType,
  }) : super(MCPContentType.image);

  factory ImageContent.fromBase64({
    required String base64Data,
    required String mimeType,
  }) {
    return ImageContent(
      url: 'data:$mimeType;base64,$base64Data',
      base64Data: base64Data,
      mimeType: mimeType,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'image',
      'url': url,
      'mime_type': mimeType,
    };
  }
}

/// Resource content representation
class ResourceContent extends Content {
  final String uri;
  final String? text;
  final String? blob;

  ResourceContent({
    required this.uri,
    this.text,
    this.blob,
  }) : super(MCPContentType.resource);

  @override
  Map<String, dynamic> toJson() {
    final json = {
      'type': 'resource',
      'uri': uri,
    };

    if (text != null) {
      json['text'] = text!;
    }

    if (blob != null) {
      json['blob'] = blob!;
    }

    return json;
  }
}

/// Tool definition
class Tool {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  Tool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'description': description,
      'inputSchema': inputSchema,
    };
  }
}

/// Tool call result
class CallToolResult {
  final List<Content> content;
  final bool isStreaming;
  final bool? isError;

  CallToolResult(
      this.content, {
        this.isStreaming = false,
        this.isError,
      });

  Map<String, dynamic> toJson() {
    return {
      'content': content.map((c) => c.toJson()).toList(),
      'is_streaming': isStreaming,
      if (isError != null) 'is_error': isError,
    };
  }
}

/// Resource definition
class Resource {
  final String uri;
  final String name;
  final String description;
  final String mimeType;
  final Map<String, dynamic>? uriTemplate; // String?에서 Map<String, dynamic>?로 변경

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

/// Resource read result
class ReadResourceResult {
  final String content;
  final String mimeType;
  final List<Content> contents;

  ReadResourceResult({
    required this.content,
    required this.mimeType,
    required this.contents,
  });

  Map<String, dynamic> toJson() {
    return {
      'content': content,
      'mime_type': mimeType,
      'contents': contents.map((c) => c.toJson()).toList(),
    };
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
          mimeType: contentMap['mime_type'],
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
  final bool isRunning;
  final int connectedSessions;
  final int registeredTools;
  final int registeredResources;
  final int registeredPrompts;
  final DateTime startTime;
  final Duration uptime;
  final Map<String, dynamic> metrics;

  ServerHealth({
    required this.isRunning,
    required this.connectedSessions,
    required this.registeredTools,
    required this.registeredResources,
    required this.registeredPrompts,
    required this.startTime,
    required this.uptime,
    required this.metrics,
  });

  Map<String, dynamic> toJson() {
    return {
      'is_running': isRunning,
      'connected_sessions': connectedSessions,
      'registered_tools': registeredTools,
      'registered_resources': registeredResources,
      'registered_prompts': registeredPrompts,
      'start_time': startTime.toIso8601String(),
      'uptime_seconds': uptime.inSeconds,
      'metrics': metrics,
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
      'session_id': sessionId,
      'type': type,
      'created_at': createdAt.toIso8601String(),
      'is_cancelled': isCancelled,
      if (requestId != null) 'request_id': requestId,
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
}

/// Client session information
class ClientSession {
  final String id;
  final ServerTransport transport;
  Map<String, dynamic> capabilities;
  final DateTime connectedAt;
  String? negotiatedProtocolVersion;
  bool isInitialized = false;
  List<Root> roots = [];

  ClientSession({
    required this.id,
    required this.transport,
    required this.capabilities,
  }) : connectedAt = DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'connected_at': connectedAt.toIso8601String(),
      'protocol_version': negotiatedProtocolVersion,
      'initialized': isInitialized,
      'capabilities': capabilities,
      'roots': roots.map((r) => r.toJson()).toList(),
    };
  }
}