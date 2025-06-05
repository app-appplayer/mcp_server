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

  /// Helper getters for backward compatibility with old boolean-based API
  bool get hasTools => tools != null;
  bool get hasResources => resources != null;
  bool get hasPrompts => prompts != null;
  bool get hasLogging => logging != null;
  bool get hasSampling => sampling != null;
  bool get hasRoots => roots != null;
  bool get hasProgress => progress != null;

  bool get toolsListChanged => tools?.listChanged ?? false;
  bool get resourcesListChanged => resources?.listChanged ?? false;
  bool get promptsListChanged => prompts?.listChanged ?? false;
  bool get rootsListChanged => roots?.listChanged ?? false;

  /// Create a simple capabilities configuration with boolean flags
  factory ServerCapabilities.simple({
    bool tools = false,
    bool toolsListChanged = false,
    bool resources = false,
    bool resourcesListChanged = false,
    bool prompts = false,
    bool promptsListChanged = false,
    bool sampling = false,
    bool logging = false,
    bool roots = false,
    bool rootsListChanged = false,
    bool progress = false,
  }) {
    return ServerCapabilities(
      tools: tools ? ToolsCapability(listChanged: toolsListChanged) : null,
      resources: resources ? ResourcesCapability(listChanged: resourcesListChanged) : null,
      prompts: prompts ? PromptsCapability(listChanged: promptsListChanged) : null,
      logging: logging ? const LoggingCapability() : null,
      sampling: sampling ? const SamplingCapability() : null,
      roots: roots ? RootsCapability(listChanged: rootsListChanged) : null,
      progress: progress ? const ProgressCapability() : null,
    );
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

