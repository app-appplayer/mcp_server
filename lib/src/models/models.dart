
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
  final List<Content> contents;
  final bool isStreaming;
  final bool? isError;

  CallToolResult(
      this.contents, {
        this.isStreaming = false,
        this.isError,
      });

  Map<String, dynamic> toJson() {
    return {
      'contents': contents.map((c) => c.toJson()).toList(),
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
  final Map<String, dynamic>? uriTemplate;

  Resource({
    required this.uri,
    required this.name,
    required this.description,
    required this.mimeType,
    this.uriTemplate,
  });

  Map<String, dynamic> toJson() {
    final result = {
      'uri': uri,
      'name': name,
      'description': description,
      'mime_type': mimeType,
    };

    if (uriTemplate != null) {
      result['uri_template'] = uriTemplate as String;
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
  final String model;
  final double? weight;

  ModelHint({
    required this.model,
    this.weight,
  });

  Map<String, dynamic> toJson() {
    final result = {'model': model};
    if (weight != null) {
      result['weight'] = weight as String;
    }
    return result;
  }
}

/// Model preferences for sampling
class ModelPreferences {
  final List<ModelHint>? hints;
  final double? intelligencePriority;
  final double? speedPriority;

  ModelPreferences({
    this.hints,
    this.intelligencePriority,
    this.speedPriority,
  });

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{};

    if (hints != null && hints!.isNotEmpty) {
      result['hints'] = hints!.map((h) => h.toJson()).toList();
    }

    if (intelligencePriority != null) {
      result['intelligence_priority'] = intelligencePriority;
    }

    if (speedPriority != null) {
      result['speed_priority'] = speedPriority;
    }

    return result;
  }
}

/// Create message request for sampling
class CreateMessageRequest {
  final Content content;
  final ModelPreferences? modelPreferences;
  final String? systemPrompt;
  final int? maxTokens;
  final double? temperature;

  CreateMessageRequest({
    required this.content,
    this.modelPreferences,
    this.systemPrompt,
    this.maxTokens,
    this.temperature,
  });

  Map<String, dynamic> toJson() {
    final result = {
      'content': content.toJson(),
    };

    if (modelPreferences != null) {
      result['model_preferences'] = modelPreferences!.toJson();
    }

    if (systemPrompt != null) {
      result['system_prompt'] = systemPrompt as Map<String, dynamic>;
    }

    if (maxTokens != null) {
      result['max_tokens'] = maxTokens as Map<String, dynamic>;
    }

    if (temperature != null) {
      result['temperature'] = temperature as Map<String, dynamic>;
    }

    return result;
  }
}

/// Create message result from sampling
class CreateMessageResult {
  final Content content;

  CreateMessageResult({required this.content});

  Map<String, dynamic> toJson() {
    return {
      'content': content.toJson(),
    };
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

    return CreateMessageResult(content: content);
  }
}

/// Root definition for filesystem access
class Root {
  final String uri;
  final String description;

  Root({
    required this.uri,
    required this.description,
  });

  Map<String, dynamic> toJson() {
    return {
      'uri': uri,
      'description': description,
    };
  }
}