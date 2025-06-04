import 'package:meta/meta.dart';

/// Server capabilities configuration for MCP 2025-03-26 protocol
@immutable
class ServerCapabilities {
  /// Tool support capabilities
  final ToolsCapability? tools;
  
  /// Resource support capabilities
  final ResourcesCapability? resources;
  
  /// Prompt support capabilities
  final PromptsCapability? prompts;
  
  /// Logging support capabilities
  final LoggingCapability? logging;
  
  /// Sampling support capabilities  
  final SamplingCapability? sampling;
  
  /// Roots support capabilities
  final RootsCapability? roots;
  
  /// Progress support capabilities
  final ProgressCapability? progress;

  const ServerCapabilities({
    this.tools,
    this.resources,
    this.prompts,
    this.logging,
    this.sampling,
    this.roots,
    this.progress,
  });

  /// Convert capabilities to JSON
  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{};
    
    if (tools != null) {
      result['tools'] = tools!.toJson();
    }
    
    if (resources != null) {
      result['resources'] = resources!.toJson();
    }
    
    if (prompts != null) {
      result['prompts'] = prompts!.toJson();
    }
    
    if (logging != null) {
      result['logging'] = logging!.toJson();
    }
    
    if (sampling != null) {
      result['sampling'] = sampling!.toJson();
    }
    
    if (roots != null) {
      result['roots'] = roots!.toJson();
    }
    
    if (progress != null) {
      result['progress'] = progress!.toJson();
    }
    
    return result;
  }
}

/// Tools capability
@immutable
class ToolsCapability {
  /// Whether the server supports list change notifications
  final bool? listChanged;
  
  /// Whether the server supports progress updates during tool execution
  final bool? supportsProgress;
  
  /// Whether the server supports cancellation of tool execution
  final bool? supportsCancellation;

  const ToolsCapability({
    this.listChanged,
    this.supportsProgress,
    this.supportsCancellation,
  });

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{};
    if (listChanged != null) result['listChanged'] = listChanged;
    if (supportsProgress != null) result['supportsProgress'] = supportsProgress;
    if (supportsCancellation != null) result['supportsCancellation'] = supportsCancellation;
    return result;
  }
}

/// Resources capability
@immutable
class ResourcesCapability {
  /// Whether the server supports resource subscriptions
  final bool? subscribe;
  
  /// Whether the server supports list change notifications
  final bool? listChanged;

  const ResourcesCapability({
    this.subscribe,
    this.listChanged,
  });

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{};
    if (subscribe != null) result['subscribe'] = subscribe;
    if (listChanged != null) result['listChanged'] = listChanged;
    return result;
  }
}

/// Prompts capability
@immutable
class PromptsCapability {
  /// Whether the server supports list change notifications
  final bool? listChanged;

  const PromptsCapability({
    this.listChanged,
  });

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{};
    if (listChanged != null) result['listChanged'] = listChanged;
    return result;
  }
}

/// Logging capability
@immutable
class LoggingCapability {
  const LoggingCapability();

  Map<String, dynamic> toJson() => {};
}

/// Sampling capability
@immutable
class SamplingCapability {
  const SamplingCapability();

  Map<String, dynamic> toJson() => {};
}

/// Roots capability
@immutable
class RootsCapability {
  /// Whether the server supports list change notifications
  final bool? listChanged;

  const RootsCapability({
    this.listChanged,
  });

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{};
    if (listChanged != null) result['listChanged'] = listChanged;
    return result;
  }
}

/// Progress capability
@immutable
class ProgressCapability {
  /// Whether the server supports progress notifications
  final bool? supportsProgress;

  const ProgressCapability({
    this.supportsProgress,
  });

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{};
    if (supportsProgress != null) result['supportsProgress'] = supportsProgress;
    return result;
  }
}

/// Protocol version management
@immutable
class McpProtocolVersion {
  /// MCP 2024-11-05 protocol version
  static const String v2024_11_05 = "2024-11-05";
  
  /// MCP 2025-03-26 protocol version
  static const String v2025_03_26 = "2025-03-26";
  
  /// Latest supported protocol version
  static const String latest = v2025_03_26;
  
  /// All supported protocol versions (newest first)
  static const List<String> supported = [v2025_03_26, v2024_11_05];
  
  /// Check if a version is supported
  static bool isSupported(String version) => supported.contains(version);
  
  /// Negotiate the best protocol version between client and server
  static String? negotiate(List<String> clientVersions, List<String> serverVersions) {
    for (final serverVersion in serverVersions) {
      if (clientVersions.contains(serverVersion)) {
        return serverVersion;
      }
    }
    return null;
  }
}