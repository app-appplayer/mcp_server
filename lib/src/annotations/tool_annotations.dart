/// Standard tool annotations for MCP 2025-03-26
library;

import 'package:meta/meta.dart';

/// Standard tool annotation keys defined in MCP 2025-03-26
class ToolAnnotationKeys {
  /// Indicates if the tool only reads data and doesn't modify anything
  static const String readOnly = 'readOnly';
  
  /// Indicates if the tool performs destructive operations
  static const String destructive = 'destructive';
  
  /// Indicates if the tool requires user confirmation before execution
  static const String requiresConfirmation = 'requiresConfirmation';
  
  /// Indicates if the tool supports progress reporting
  static const String supportsProgress = 'supportsProgress';
  
  /// Indicates if the tool supports cancellation
  static const String supportsCancellation = 'supportsCancellation';
  
  /// Estimated execution time in seconds
  static const String estimatedDuration = 'estimatedDuration';
  
  /// Tool category for organization
  static const String category = 'category';
  
  /// Tool priority level
  static const String priority = 'priority';
  
  /// Whether the tool is experimental
  static const String experimental = 'experimental';
  
  /// Minimum required API version
  static const String minApiVersion = 'minApiVersion';
  
  /// Tool deprecation information
  static const String deprecated = 'deprecated';
  
  /// Usage examples or documentation links
  static const String examples = 'examples';
  
  /// Required permissions or scopes
  static const String requiredPermissions = 'requiredPermissions';
  
  /// Resource consumption hints
  static const String resourceUsage = 'resourceUsage';
}

/// Tool priority levels
enum ToolPriority {
  low,
  normal,
  high,
  critical;
  
  @override
  String toString() => name;
}

/// Resource usage indicators
@immutable
class ResourceUsage {
  /// CPU usage level (low, medium, high)
  final String cpu;
  
  /// Memory usage level (low, medium, high)
  final String memory;
  
  /// Network usage level (low, medium, high)
  final String network;
  
  /// Disk usage level (low, medium, high)
  final String disk;
  
  const ResourceUsage({
    this.cpu = 'low',
    this.memory = 'low',
    this.network = 'low',
    this.disk = 'low',
  });
  
  Map<String, dynamic> toJson() => {
    'cpu': cpu,
    'memory': memory,
    'network': network,
    'disk': disk,
  };
  
  factory ResourceUsage.fromJson(Map<String, dynamic> json) => ResourceUsage(
    cpu: json['cpu'] as String? ?? 'low',
    memory: json['memory'] as String? ?? 'low',
    network: json['network'] as String? ?? 'low',
    disk: json['disk'] as String? ?? 'low',
  );
}

/// Deprecation information
@immutable
class DeprecationInfo {
  /// Version when the tool was deprecated
  final String version;
  
  /// Reason for deprecation
  final String reason;
  
  /// Recommended replacement tool
  final String? replacement;
  
  /// Planned removal version
  final String? removalVersion;
  
  const DeprecationInfo({
    required this.version,
    required this.reason,
    this.replacement,
    this.removalVersion,
  });
  
  Map<String, dynamic> toJson() => {
    'version': version,
    'reason': reason,
    if (replacement != null) 'replacement': replacement,
    if (removalVersion != null) 'removalVersion': removalVersion,
  };
  
  factory DeprecationInfo.fromJson(Map<String, dynamic> json) => DeprecationInfo(
    version: json['version'] as String,
    reason: json['reason'] as String,
    replacement: json['replacement'] as String?,
    removalVersion: json['removalVersion'] as String?,
  );
}

/// Tool annotation builder for creating standard annotations
class ToolAnnotationBuilder {
  final Map<String, dynamic> _annotations = {};
  
  /// Mark tool as read-only
  ToolAnnotationBuilder readOnly([bool value = true]) {
    _annotations[ToolAnnotationKeys.readOnly] = value;
    return this;
  }
  
  /// Mark tool as destructive
  ToolAnnotationBuilder destructive([bool value = true]) {
    _annotations[ToolAnnotationKeys.destructive] = value;
    return this;
  }
  
  /// Mark tool as requiring confirmation
  ToolAnnotationBuilder requiresConfirmation([bool value = true]) {
    _annotations[ToolAnnotationKeys.requiresConfirmation] = value;
    return this;
  }
  
  /// Mark tool as supporting progress
  ToolAnnotationBuilder supportsProgress([bool value = true]) {
    _annotations[ToolAnnotationKeys.supportsProgress] = value;
    return this;
  }
  
  /// Mark tool as supporting cancellation
  ToolAnnotationBuilder supportsCancellation([bool value = true]) {
    _annotations[ToolAnnotationKeys.supportsCancellation] = value;
    return this;
  }
  
  /// Set estimated execution duration in seconds
  ToolAnnotationBuilder estimatedDuration(int seconds) {
    _annotations[ToolAnnotationKeys.estimatedDuration] = seconds;
    return this;
  }
  
  /// Set tool category
  ToolAnnotationBuilder category(String category) {
    _annotations[ToolAnnotationKeys.category] = category;
    return this;
  }
  
  /// Set tool priority
  ToolAnnotationBuilder priority(ToolPriority priority) {
    _annotations[ToolAnnotationKeys.priority] = priority.toString();
    return this;
  }
  
  /// Mark tool as experimental
  ToolAnnotationBuilder experimental([bool value = true]) {
    _annotations[ToolAnnotationKeys.experimental] = value;
    return this;
  }
  
  /// Set minimum required API version
  ToolAnnotationBuilder minApiVersion(String version) {
    _annotations[ToolAnnotationKeys.minApiVersion] = version;
    return this;
  }
  
  /// Mark tool as deprecated
  ToolAnnotationBuilder deprecated(DeprecationInfo info) {
    _annotations[ToolAnnotationKeys.deprecated] = info.toJson();
    return this;
  }
  
  /// Add usage examples
  ToolAnnotationBuilder examples(List<String> examples) {
    _annotations[ToolAnnotationKeys.examples] = examples;
    return this;
  }
  
  /// Set required permissions
  ToolAnnotationBuilder requiredPermissions(List<String> permissions) {
    _annotations[ToolAnnotationKeys.requiredPermissions] = permissions;
    return this;
  }
  
  /// Set resource usage information
  ToolAnnotationBuilder resourceUsage(ResourceUsage usage) {
    _annotations[ToolAnnotationKeys.resourceUsage] = usage.toJson();
    return this;
  }
  
  /// Add custom annotation
  ToolAnnotationBuilder custom(String key, dynamic value) {
    _annotations[key] = value;
    return this;
  }
  
  /// Build the annotations map
  Map<String, dynamic> build() => Map.unmodifiable(_annotations);
}

/// Utility functions for working with tool annotations
class ToolAnnotationUtils {
  /// Check if a tool is read-only
  static bool isReadOnly(Map<String, dynamic>? annotations) {
    return annotations?[ToolAnnotationKeys.readOnly] == true;
  }
  
  /// Check if a tool is destructive
  static bool isDestructive(Map<String, dynamic>? annotations) {
    return annotations?[ToolAnnotationKeys.destructive] == true;
  }
  
  /// Check if a tool requires confirmation
  static bool requiresConfirmation(Map<String, dynamic>? annotations) {
    return annotations?[ToolAnnotationKeys.requiresConfirmation] == true;
  }
  
  /// Check if a tool supports progress
  static bool supportsProgress(Map<String, dynamic>? annotations) {
    return annotations?[ToolAnnotationKeys.supportsProgress] == true;
  }
  
  /// Check if a tool supports cancellation
  static bool supportsCancellation(Map<String, dynamic>? annotations) {
    return annotations?[ToolAnnotationKeys.supportsCancellation] == true;
  }
  
  /// Get estimated duration in seconds
  static int? getEstimatedDuration(Map<String, dynamic>? annotations) {
    final duration = annotations?[ToolAnnotationKeys.estimatedDuration];
    return duration is int ? duration : null;
  }
  
  /// Get tool category
  static String? getCategory(Map<String, dynamic>? annotations) {
    return annotations?[ToolAnnotationKeys.category] as String?;
  }
  
  /// Get tool priority
  static ToolPriority? getPriority(Map<String, dynamic>? annotations) {
    final priority = annotations?[ToolAnnotationKeys.priority] as String?;
    if (priority == null) return null;
    
    return ToolPriority.values.cast<ToolPriority?>().firstWhere(
      (p) => p?.toString() == priority,
      orElse: () => null,
    );
  }
  
  /// Check if a tool is experimental
  static bool isExperimental(Map<String, dynamic>? annotations) {
    return annotations?[ToolAnnotationKeys.experimental] == true;
  }
  
  /// Get minimum API version
  static String? getMinApiVersion(Map<String, dynamic>? annotations) {
    return annotations?[ToolAnnotationKeys.minApiVersion] as String?;
  }
  
  /// Get deprecation information
  static DeprecationInfo? getDeprecationInfo(Map<String, dynamic>? annotations) {
    final deprecated = annotations?[ToolAnnotationKeys.deprecated];
    if (deprecated is Map<String, dynamic>) {
      return DeprecationInfo.fromJson(deprecated);
    }
    return null;
  }
  
  /// Check if a tool is deprecated
  static bool isDeprecated(Map<String, dynamic>? annotations) {
    return getDeprecationInfo(annotations) != null;
  }
  
  /// Get usage examples
  static List<String>? getExamples(Map<String, dynamic>? annotations) {
    final examples = annotations?[ToolAnnotationKeys.examples];
    return examples is List ? examples.cast<String>() : null;
  }
  
  /// Get required permissions
  static List<String>? getRequiredPermissions(Map<String, dynamic>? annotations) {
    final permissions = annotations?[ToolAnnotationKeys.requiredPermissions];
    return permissions is List ? permissions.cast<String>() : null;
  }
  
  /// Get resource usage information
  static ResourceUsage? getResourceUsage(Map<String, dynamic>? annotations) {
    final usage = annotations?[ToolAnnotationKeys.resourceUsage];
    if (usage is Map<String, dynamic>) {
      return ResourceUsage.fromJson(usage);
    }
    return null;
  }
  
  /// Validate annotations against MCP 2025-03-26 standards
  static List<String> validateAnnotations(Map<String, dynamic> annotations) {
    final errors = <String>[];
    
    // Check for conflicting annotations
    if (isReadOnly(annotations) && isDestructive(annotations)) {
      errors.add('Tool cannot be both readOnly and destructive');
    }
    
    // Validate priority
    final priority = annotations[ToolAnnotationKeys.priority];
    if (priority != null && priority is String) {
      try {
        ToolPriority.values.firstWhere((p) => p.toString() == priority);
      } catch (e) {
        errors.add('Invalid priority value: $priority');
      }
    }
    
    // Validate estimated duration
    final duration = annotations[ToolAnnotationKeys.estimatedDuration];
    if (duration != null && (duration is! int || duration < 0)) {
      errors.add('estimatedDuration must be a non-negative integer');
    }
    
    // Validate resource usage
    final usage = annotations[ToolAnnotationKeys.resourceUsage];
    if (usage != null && usage is Map<String, dynamic>) {
      final validLevels = ['low', 'medium', 'high'];
      for (final level in ['cpu', 'memory', 'network', 'disk']) {
        final value = usage[level];
        if (value != null && !validLevels.contains(value)) {
          errors.add('Invalid $level usage level: $value. Must be one of $validLevels');
        }
      }
    }
    
    return errors;
  }
  
  /// Create a tool annotation builder
  static ToolAnnotationBuilder builder() => ToolAnnotationBuilder();
}

/// Common tool annotation presets
class ToolAnnotationPresets {
  /// Safe read-only tool
  static Map<String, dynamic> readOnlyTool({
    String? category,
    ToolPriority? priority,
  }) => ToolAnnotationUtils.builder()
    .readOnly()
    .category(category ?? 'data')
    .priority(priority ?? ToolPriority.normal)
    .build();
  
  /// Destructive operation tool
  static Map<String, dynamic> destructiveTool({
    String? category,
    ToolPriority? priority,
  }) => ToolAnnotationUtils.builder()
    .destructive()
    .requiresConfirmation()
    .category(category ?? 'system')
    .priority(priority ?? ToolPriority.high)
    .build();
  
  /// Long-running tool with progress
  static Map<String, dynamic> longRunningTool({
    int? estimatedDuration,
    String? category,
  }) => ToolAnnotationUtils.builder()
    .supportsProgress()
    .supportsCancellation()
    .estimatedDuration(estimatedDuration ?? 300) // 5 minutes default
    .category(category ?? 'processing')
    .build();
  
  /// Experimental tool
  static Map<String, dynamic> experimentalTool({
    String? minApiVersion,
  }) => ToolAnnotationUtils.builder()
    .experimental()
    .minApiVersion(minApiVersion ?? '2025-03-26')
    .priority(ToolPriority.low)
    .build();
  
  /// High-resource usage tool
  static Map<String, dynamic> heavyTool() => ToolAnnotationUtils.builder()
    .resourceUsage(const ResourceUsage(
      cpu: 'high',
      memory: 'high',
    ))
    .supportsProgress()
    .supportsCancellation()
    .estimatedDuration(600) // 10 minutes
    .build();
}