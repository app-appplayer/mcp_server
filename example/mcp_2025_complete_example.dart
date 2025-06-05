/// Comprehensive MCP 2025-03-26 server example showcasing current API features
/// 
/// This example demonstrates the current stable API with working implementations.
library;

import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:mcp_server/mcp_server.dart';

void main() async {
  // Initialize server with enhanced capabilities
  await runCompleteMcpServer();
}

/// Complete MCP server implementation showcasing current API features
Future<void> runCompleteMcpServer() async {
  final logger = Logger('complete_mcp_server');
  logger.info('🚀 Starting Complete MCP 2025-03-26 Server...');

  // Create server with advanced capabilities
  final server = Server(
    name: 'MCP 2025 Complete Server',
    version: '2.0.0',
    capabilities: ServerCapabilities(
      tools: ToolsCapability(
        listChanged: true,
      ),
      resources: ResourcesCapability(
        listChanged: true,
        subscribe: true,
      ),
      prompts: PromptsCapability(
        listChanged: true,
      ),
      sampling: SamplingCapability(),
      logging: LoggingCapability(),
      progress: ProgressCapability(
        supportsProgress: true,
      ),
    ),
  );

  // Register comprehensive functionality
  _registerAdvancedTools(server, logger);
  _registerDynamicResources(server, logger);
  _registerSmartPrompts(server, logger);
  
  // Set up event handlers
  _setupEventHandlers(server, logger);

  // Connect to STDIO transport
  final transportResult = McpServer.createStdioTransport();
  final transport = transportResult.get();
  server.connect(transport);

  logger.info('✅ Complete server started successfully');
  logger.info('📝 Registered ${server.getTools().length} tools');
  logger.info('📂 Registered ${server.getResources().length} resources');
  logger.info('💬 Registered ${server.getPrompts().length} prompts');
  
  await transport.onClose;
  logger.info('🔚 Server shutdown complete');
}

/// Register advanced tools demonstrating current API capabilities
void _registerAdvancedTools(Server server, Logger logger) {
  logger.info('📝 Registering advanced tools...');

  // System diagnostics tool
  server.addTool(
    name: 'system_diagnostics',
    description: 'Comprehensive system diagnostics and health check',
    inputSchema: {
      'type': 'object',
      'properties': {
        'include_processes': {
          'type': 'boolean',
          'description': 'Include running processes information',
          'default': false,
        },
        'include_network': {
          'type': 'boolean',
          'description': 'Include network configuration',
          'default': false,
        },
        'format': {
          'type': 'string',
          'enum': ['json', 'text'],
          'description': 'Output format',
          'default': 'text',
        },
      },
    },
    handler: (arguments) async {
      final includeProcesses = arguments['include_processes'] as bool? ?? false;
      final includeNetwork = arguments['include_network'] as bool? ?? false;
      final format = arguments['format'] as String? ?? 'text';
      
      final diagnostics = <String, dynamic>{
        'timestamp': DateTime.now().toIso8601String(),
        'platform': Platform.operatingSystem,
        'version': Platform.operatingSystemVersion,
        'dart_version': Platform.version,
        'processors': Platform.numberOfProcessors,
        'locale': Platform.localeName,
        'executable': Platform.executable,
      };
      
      if (includeProcesses) {
        // Add process information (simplified for security)
        diagnostics['current_process'] = {
          'pid': pid,
          'executable_path': Platform.resolvedExecutable,
        };
      }
      
      if (includeNetwork) {
        diagnostics['network'] = {
          'hostname': Platform.localHostname,
        };
      }
      
      if (format == 'json') {
        return CallToolResult(
          content: [TextContent(text: jsonEncode(diagnostics))],
        );
      } else {
        final buffer = StringBuffer('System Diagnostics\\n');
        buffer.writeln('================');
        diagnostics.forEach((key, value) {
          if (value is Map) {
            buffer.writeln('$key:');
            value.forEach((k, v) => buffer.writeln('  $k: $v'));
          } else {
            buffer.writeln('$key: $value');
          }
        });
        
        return CallToolResult(
          content: [TextContent(text: buffer.toString())],
        );
      }
    },
  );

  // File operations tool
  server.addTool(
    name: 'file_operations',
    description: 'Safe file operations within temporary directory',
    inputSchema: {
      'type': 'object',
      'properties': {
        'operation': {
          'type': 'string',
          'enum': ['list', 'read', 'write', 'delete', 'stat'],
          'description': 'File operation to perform',
        },
        'path': {
          'type': 'string',
          'description': 'Relative path within temp directory',
        },
        'content': {
          'type': 'string',
          'description': 'Content for write operation',
        },
      },
      'required': ['operation', 'path'],
    },
    handler: (arguments) async {
      final operation = arguments['operation'] as String;
      final relativePath = arguments['path'] as String;
      final content = arguments['content'] as String?;
      
      // Security: Only allow operations within temp directory
      final tempDir = Directory.systemTemp;
      final fullPath = '${tempDir.path}/$relativePath';
      
      // Prevent directory traversal
      if (!fullPath.startsWith(tempDir.path)) {
        return CallToolResult(
          content: [TextContent(text: 'Error: Path outside allowed directory')],
          isError: true,
        );
      }
      
      try {
        switch (operation) {
          case 'list':
            final dir = Directory(fullPath);
            if (!await dir.exists()) {
              return CallToolResult(
                content: [TextContent(text: 'Directory not found')],
                isError: true,
              );
            }
            final entries = await dir.list().map((e) => e.path.split('/').last).toList();
            return CallToolResult(
              content: [TextContent(text: 'Files: ${entries.join(', ')}')],
            );
            
          case 'read':
            final file = File(fullPath);
            if (!await file.exists()) {
              return CallToolResult(
                content: [TextContent(text: 'File not found')],
                isError: true,
              );
            }
            final fileContent = await file.readAsString();
            return CallToolResult(
              content: [TextContent(text: fileContent)],
            );
            
          case 'write':
            if (content == null) {
              return CallToolResult(
                content: [TextContent(text: 'Content required for write operation')],
                isError: true,
              );
            }
            final file = File(fullPath);
            await file.parent.create(recursive: true);
            await file.writeAsString(content);
            return CallToolResult(
              content: [TextContent(text: 'File written successfully')],
            );
            
          case 'delete':
            final file = File(fullPath);
            if (!await file.exists()) {
              return CallToolResult(
                content: [TextContent(text: 'File not found')],
                isError: true,
              );
            }
            await file.delete();
            return CallToolResult(
              content: [TextContent(text: 'File deleted successfully')],
            );
            
          case 'stat':
            final file = File(fullPath);
            if (!await file.exists()) {
              return CallToolResult(
                content: [TextContent(text: 'File not found')],
                isError: true,
              );
            }
            final stat = await file.stat();
            return CallToolResult(
              content: [TextContent(text: '''File Statistics:
Size: ${stat.size} bytes
Modified: ${stat.modified}
Type: ${stat.type}
Mode: ${stat.mode.toRadixString(8)}''')],
            );
            
          default:
            return CallToolResult(
              content: [TextContent(text: 'Unknown operation: $operation')],
              isError: true,
            );
        }
      } catch (e) {
        return CallToolResult(
          content: [TextContent(text: 'Operation failed: $e')],
          isError: true,
        );
      }
    },
  );

  // Enhanced calculator with history
  server.addTool(
    name: 'enhanced_calculator',
    description: 'Advanced calculator with operation history',
    inputSchema: {
      'type': 'object',
      'properties': {
        'expression': {
          'type': 'string',
          'description': 'Mathematical expression to evaluate',
        },
        'save_to_history': {
          'type': 'boolean',
          'description': 'Save result to calculation history',
          'default': true,
        },
        'show_history': {
          'type': 'boolean',
          'description': 'Show calculation history',
          'default': false,
        },
      },
      'required': ['expression'],
    },
    handler: (arguments) async {
      final expression = arguments['expression'] as String;
      final _ = arguments['save_to_history'] as bool? ?? true; // Future: save to history
      final showHistory = arguments['show_history'] as bool? ?? false;
      
      // Simple expression evaluator (basic operations only for security)
      try {
        final result = _evaluateExpression(expression);
        
        final buffer = StringBuffer();
        buffer.writeln('$expression = $result');
        
        if (showHistory) {
          buffer.writeln('\\nCalculation History:');
          // In a real implementation, you'd maintain history
          buffer.writeln('(History feature would be implemented here)');
        }
        
        return CallToolResult(
          content: [TextContent(text: buffer.toString())],
        );
      } catch (e) {
        return CallToolResult(
          content: [TextContent(text: 'Invalid expression: $e')],
          isError: true,
        );
      }
    },
  );

  logger.info('✅ Advanced tools registered successfully');
}

/// Simple expression evaluator for basic math operations
double _evaluateExpression(String expression) {
  // Remove whitespace
  expression = expression.replaceAll(' ', '');
  
  // Simple regex-based calculator for basic operations
  final addSubtractRegex = RegExp(r'^([+-]?\d*\.?\d+)([+-])(\d*\.?\d+)$');
  final multiplyDivideRegex = RegExp(r'^([+-]?\d*\.?\d+)([*/])(\d*\.?\d+)$');
  
  // Try multiply/divide first (higher precedence)
  var match = multiplyDivideRegex.firstMatch(expression);
  if (match != null) {
    final a = double.parse(match.group(1)!);
    final operator = match.group(2)!;
    final b = double.parse(match.group(3)!);
    
    switch (operator) {
      case '*':
        return a * b;
      case '/':
        if (b == 0) throw ArgumentError('Division by zero');
        return a / b;
    }
  }
  
  // Try add/subtract
  match = addSubtractRegex.firstMatch(expression);
  if (match != null) {
    final a = double.parse(match.group(1)!);
    final operator = match.group(2)!;
    final b = double.parse(match.group(3)!);
    
    switch (operator) {
      case '+':
        return a + b;
      case '-':
        return a - b;
    }
  }
  
  // Try single number
  return double.parse(expression);
}

/// Register dynamic resources with current API
void _registerDynamicResources(Server server, Logger logger) {
  logger.info('📂 Registering dynamic resources...');

  // System metrics resource
  server.addResource(
    uri: 'system://metrics',
    name: 'System Metrics',
    description: 'Real-time system performance metrics',
    mimeType: 'application/json',
    handler: (uri, params) async {
      final metrics = {
        'timestamp': DateTime.now().toIso8601String(),
        'system': {
          'platform': Platform.operatingSystem,
          'processors': Platform.numberOfProcessors,
          'dart_version': Platform.version,
        },
        'runtime': {
          'uptime_seconds': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'executable': Platform.executable,
        },
      };
      
      return ReadResourceResult(
        contents: [
          ResourceContentInfo(
            uri: uri,
            mimeType: 'application/json',
            text: jsonEncode(metrics),
          ),
        ],
      );
    },
  );

  // Configuration resource
  server.addResource(
    uri: 'config://server',
    name: 'Server Configuration',
    description: 'Current server configuration and capabilities',
    mimeType: 'application/json',
    handler: (uri, params) async {
      final config = {
        'server_info': {
          'name': server.name,
          'version': server.version,
        },
        'capabilities': {
          'tools': server.capabilities.hasTools,
          'resources': server.capabilities.hasResources,
          'prompts': server.capabilities.hasPrompts,
          'sampling': server.capabilities.hasSampling,
          'logging': server.capabilities.hasLogging,
          'progress': server.capabilities.hasProgress,
        },
        'registered_counts': {
          'tools': server.getTools().length,
          'resources': server.getResources().length,
          'prompts': server.getPrompts().length,
        },
      };
      
      return ReadResourceResult(
        contents: [
          ResourceContentInfo(
            uri: uri,
            mimeType: 'application/json',
            text: jsonEncode(config),
          ),
        ],
      );
    },
  );

  // Environment resource
  server.addResource(
    uri: 'env://variables',
    name: 'Environment Variables',
    description: 'System environment variables (filtered for security)',
    mimeType: 'application/json',
    handler: (uri, params) async {
      // Filter environment variables for security
      final safeEnvVars = <String, String>{};
      final allowedPrefixes = ['DART_', 'PUB_', 'PATH', 'HOME', 'USER'];
      
      Platform.environment.forEach((key, value) {
        if (allowedPrefixes.any((prefix) => key.startsWith(prefix))) {
          safeEnvVars[key] = value;
        }
      });
      
      return ReadResourceResult(
        contents: [
          ResourceContentInfo(
            uri: uri,
            mimeType: 'application/json',
            text: jsonEncode({
              'filtered_count': safeEnvVars.length,
              'total_count': Platform.environment.length,
              'variables': safeEnvVars,
            }),
          ),
        ],
      );
    },
  );

  logger.info('✅ Dynamic resources registered successfully');
}

/// Register smart prompts with argument handling
void _registerSmartPrompts(Server server, Logger logger) {
  logger.info('💬 Registering smart prompts...');

  // Code analysis prompt
  server.addPrompt(
    name: 'analyze_code',
    description: 'Generate a comprehensive code analysis prompt',
    arguments: [
      PromptArgument(
        name: 'language',
        description: 'Programming language (dart, python, javascript, etc.)',
        required: true,
      ),
      PromptArgument(
        name: 'analysis_type',
        description: 'Type of analysis (security, performance, style, all)',
        required: false,
      ),
      PromptArgument(
        name: 'complexity',
        description: 'Code complexity level (beginner, intermediate, advanced)',
        required: false,
      ),
    ],
    handler: (arguments) async {
      final language = arguments['language'] as String;
      final analysisType = arguments['analysis_type'] as String? ?? 'all';
      final complexity = arguments['complexity'] as String? ?? 'intermediate';
      
      String focusArea;
      switch (analysisType) {
        case 'security':
          focusArea = 'Focus on security vulnerabilities, input validation, and secure coding practices.';
          break;
        case 'performance':
          focusArea = 'Focus on performance optimizations, algorithmic complexity, and resource usage.';
          break;
        case 'style':
          focusArea = 'Focus on code style, naming conventions, and maintainability.';
          break;
        default:
          focusArea = 'Provide a comprehensive analysis covering security, performance, style, and best practices.';
      }
      
      String complexityGuidance;
      switch (complexity) {
        case 'beginner':
          complexityGuidance = 'Provide explanations suitable for beginners with clear examples.';
          break;
        case 'advanced':
          complexityGuidance = 'Assume advanced knowledge and provide detailed technical insights.';
          break;
        default:
          complexityGuidance = 'Provide intermediate-level analysis with balanced detail.';
      }
      
      return GetPromptResult(
        description: 'Code analysis prompt for $language ($analysisType focus)',
        messages: [
          Message(
            role: 'system',
            content: TextContent(
              text: '''You are an expert $language developer and code reviewer.

$focusArea

$complexityGuidance

Please analyze the provided code and provide:
1. Overall code quality assessment
2. Specific issues or improvements identified
3. Best practices recommendations
4. Suggestions for optimization or refactoring

Be constructive and educational in your feedback.''',
            ),
          ),
        ],
      );
    },
  );

  // Documentation prompt
  server.addPrompt(
    name: 'generate_docs',
    description: 'Generate documentation for code or APIs',
    arguments: [
      PromptArgument(
        name: 'doc_type',
        description: 'Type of documentation (api, readme, comments, tutorial)',
        required: true,
      ),
      PromptArgument(
        name: 'audience',
        description: 'Target audience (developer, end-user, maintainer)',
        required: false,
      ),
      PromptArgument(
        name: 'format',
        description: 'Documentation format (markdown, html, plain)',
        required: false,
      ),
    ],
    handler: (arguments) async {
      final docType = arguments['doc_type'] as String;
      final audience = arguments['audience'] as String? ?? 'developer';
      final format = arguments['format'] as String? ?? 'markdown';
      
      String docInstructions;
      switch (docType) {
        case 'api':
          docInstructions = 'Create comprehensive API documentation including endpoints, parameters, responses, and examples.';
          break;
        case 'readme':
          docInstructions = 'Create a README file with project overview, installation, usage, and contribution guidelines.';
          break;
        case 'comments':
          docInstructions = 'Add inline code comments and documentation strings to explain complex logic.';
          break;
        case 'tutorial':
          docInstructions = 'Create a step-by-step tutorial with examples and explanations.';
          break;
        default:
          docInstructions = 'Generate appropriate documentation for the provided content.';
      }
      
      String audienceGuidance;
      switch (audience) {
        case 'end-user':
          audienceGuidance = 'Write for end users with non-technical language and focus on functionality.';
          break;
        case 'maintainer':
          audienceGuidance = 'Write for code maintainers with technical details and architecture information.';
          break;
        default:
          audienceGuidance = 'Write for developers with technical accuracy and practical examples.';
      }
      
      return GetPromptResult(
        description: 'Documentation generation for $docType ($audience audience)',
        messages: [
          Message(
            role: 'system',
            content: TextContent(
              text: '''You are a technical documentation expert.

$docInstructions

$audienceGuidance

Use $format formatting where appropriate.

Ensure the documentation is:
- Clear and well-structured
- Accurate and up-to-date
- Includes relevant examples
- Follows documentation best practices

Provide comprehensive documentation for the given content.''',
            ),
          ),
        ],
      );
    },
  );

  // Problem-solving prompt
  server.addPrompt(
    name: 'debug_helper',
    description: 'Generate debugging and problem-solving prompts',
    arguments: [
      PromptArgument(
        name: 'error_type',
        description: 'Type of error or problem (runtime, compile, logic, performance)',
        required: true,
      ),
      PromptArgument(
        name: 'technology',
        description: 'Technology stack or platform',
        required: false,
      ),
    ],
    handler: (arguments) async {
      final errorType = arguments['error_type'] as String;
      final technology = arguments['technology'] as String? ?? 'general';
      
      String debuggingApproach;
      switch (errorType) {
        case 'runtime':
          debuggingApproach = 'Focus on runtime error analysis, stack traces, and execution flow.';
          break;
        case 'compile':
          debuggingApproach = 'Focus on compilation errors, syntax issues, and build problems.';
          break;
        case 'logic':
          debuggingApproach = 'Focus on logical errors, unexpected behavior, and algorithm issues.';
          break;
        case 'performance':
          debuggingApproach = 'Focus on performance bottlenecks, profiling, and optimization.';
          break;
        default:
          debuggingApproach = 'Provide general debugging guidance and systematic problem-solving.';
      }
      
      return GetPromptResult(
        description: 'Debug helper for $errorType errors in $technology',
        messages: [
          Message(
            role: 'system',
            content: TextContent(
              text: '''You are an expert debugging assistant for $technology development.

$debuggingApproach

Provide systematic debugging guidance:
1. Analyze the problem description
2. Suggest debugging steps and techniques
3. Recommend tools and methods
4. Provide troubleshooting strategies
5. Suggest preventive measures

Be methodical and provide actionable debugging advice.''',
            ),
          ),
        ],
      );
    },
  );

  logger.info('✅ Smart prompts registered successfully');
}

/// Set up event handlers for server lifecycle events
void _setupEventHandlers(Server server, Logger logger) {
  logger.info('📡 Setting up event handlers...');

  // Listen for client connections
  server.onConnect.listen((session) {
    logger.info('🔗 Client connected: ${session.id}');
  });

  // Listen for client disconnections
  server.onDisconnect.listen((session) {
    logger.info('🔌 Client disconnected: ${session.id}');
  });

  logger.info('✅ Event handlers configured successfully');
}

// TODO: The following functions are examples of future enhancements

/*
/// Register tools with comprehensive 2025-03-26 annotations
void _registerEnhancedTools(Server server) {
  print('📝 Registering enhanced tools with annotations...');

  // Safe read-only tool
  server.addTool(
    name: 'get_system_info',
    description: 'Get system information and health status',
    inputSchema: {
        'type': 'object',
        'properties': {
          'detailed': {
            'type': 'boolean',
            'description': 'Include detailed system metrics',
            'default': false,
          }
        },
      },
    handler: (arguments) async {
      final detailed = arguments['detailed'] as bool? ?? false;
      
      final info = <String, dynamic>{
        'platform': Platform.operatingSystem,
        'version': Platform.operatingSystemVersion,
        'dart_version': Platform.version,
        'timestamp': DateTime.now().toIso8601String(),
      };
      
      if (detailed) {
        info.addAll({
          'processors': Platform.numberOfProcessors,
          'executable': Platform.executable,
          'resolved_executable': Platform.resolvedExecutable,
        });
      }
      
      return CallToolResult(
        content: [
          TextContent(
            text: 'System Information:\n${jsonEncode(info)}',
            annotations: {
              'format': 'json',
              'category': 'system_info',
            },
          ),
        ],
      );
    },
  );

  // Destructive tool with confirmation
  server.addTool(
    name: 'delete_file',
    description: 'Delete a file from the filesystem',
    inputSchema: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Path to the file to delete',
          },
          'confirm': {
            'type': 'boolean',
            'description': 'Confirmation that you want to delete the file',
          },
        },
        'required': ['path', 'confirm'],
      },
    handler: (arguments) async {
      final path = arguments['path'] as String;
      final confirm = arguments['confirm'] as bool;
      
      if (!confirm) {
        return CallToolResult(
          content: [TextContent(text: 'File deletion cancelled - confirmation required')],
          isError: true,
        );
      }
      
      try {
        final file = File(path);
        if (!await file.exists()) {
          return CallToolResult(
            content: [TextContent(text: 'File not found: $path')],
            isError: true,
          );
        }
        
        await file.delete();
        return CallToolResult(
          content: [TextContent(text: 'Successfully deleted file: $path')],
        );
      } catch (e) {
        return CallToolResult(
          content: [TextContent(text: 'Failed to delete file: $e')],
          isError: true,
        );
      }
    },
  );

  // Long-running tool with progress and cancellation
  server.addTool(
    Tool(
      name: 'process_large_dataset',
      description: 'Process a large dataset with progress reporting',
      supportsProgress: true,
      supportsCancellation: true,
      annotations: ToolAnnotationUtils.builder()
          .supportsProgress()
          .supportsCancellation()
          .category('data_processing')
          .estimatedDuration(300) // 5 minutes
          .resourceUsage(const ResourceUsage(
            cpu: 'high',
            memory: 'medium',
          ))
          .build(),
      inputSchema: {
        'type': 'object',
        'properties': {
          'dataset_size': {
            'type': 'integer',
            'description': 'Number of items to process',
            'minimum': 1,
            'maximum': 10000,
          },
          'delay_ms': {
            'type': 'integer',
            'description': 'Delay between items in milliseconds',
            'default': 100,
          },
        },
        'required': ['dataset_size'],
      },
    ),
    (arguments) async {
      final datasetSize = arguments['dataset_size'] as int;
      final delayMs = arguments['delay_ms'] as int? ?? 100;
      
      final processed = <String>[];
      
      for (int i = 0; i < datasetSize; i++) {
        // Simulate processing
        await Future.delayed(Duration(milliseconds: delayMs));
        
        // Report progress (this would be handled by the server's progress system)
        final progress = (i + 1) / datasetSize;
        processed.add('item_${i + 1}');
        
        // Check for cancellation (would be implemented in real server)
        // if (isCancelled) break;
        
        // Report progress every 10%
        if ((i + 1) % (datasetSize ~/ 10).clamp(1, datasetSize) == 0) {
          print('Progress: ${(progress * 100).toStringAsFixed(1)}%');
        }
      }
      
      return CallToolResult(
        content: [
          TextContent(
            text: 'Processing complete!\nProcessed ${processed.length} items',
            annotations: {
              'processed_count': processed.length,
              'completion_time': DateTime.now().toIso8601String(),
            },
          ),
        ],
      );
    },
  );

  // Experimental tool
  server.addTool(
    Tool(
      name: 'ai_analyze_image',
      description: 'Experimental AI image analysis (demo)',
      annotations: ToolAnnotationUtils.builder()
          .experimental()
          .category('ai')
          .minApiVersion('2025-03-26')
          .priority(ToolPriority.low)
          .examples([
            'ai_analyze_image {"image_url": "https://example.com/image.jpg"}',
            'ai_analyze_image {"image_data": "base64..."}',
          ])
          .build(),
      inputSchema: {
        'type': 'object',
        'properties': {
          'image_url': {
            'type': 'string',
            'description': 'URL of the image to analyze',
          },
          'image_data': {
            'type': 'string',
            'description': 'Base64 encoded image data',
          },
        },
        'oneOf': [
          {'required': ['image_url']},
          {'required': ['image_data']},
        ],
      },
    ),
    (arguments) async {
      // Simulate AI image analysis
      await Future.delayed(const Duration(seconds: 2));
      
      return CallToolResult(
        content: [
          const TextContent(
            text: 'AI Analysis Results (Experimental)',
            annotations: {
              'confidence': 0.85,
              'model': 'vision-experimental-v1',
              'detected_objects': ['person', 'car', 'building'],
              'scene_type': 'urban',
            },
          ),
          const ImageContent(
            data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
            mimeType: 'image/png',
            annotations: {
              'type': 'analysis_overlay',
              'overlay_type': 'bounding_boxes',
            },
          ),
        ],
      );
    },
  );

  print('✅ Enhanced tools registered successfully');
}

/// Register resource templates for dynamic access
void _registerResourceTemplates(Server server) {
  print('📂 Registering resource templates...');

  // File system template
  server.addResourceTemplate(
    ResourceTemplate(
      uriTemplate: 'file:///{path}',
      name: 'File System Access',
      description: 'Access files and directories',
      mimeType: 'text/plain',
    ),
    (uri) async {
      final path = uri.replaceFirst('file:///', '');
      final file = File(path);
      
      if (!await file.exists()) {
        throw Exception('File not found: $path');
      }
      
      final content = await file.readAsString();
      final stats = await file.stat();
      
      return ReadResourceResult(
        contents: [
          ResourceContentInfo(
            uri: uri,
            mimeType: _getMimeType(path),
            text: content,
            annotations: {
              'file_size': stats.size,
              'modified': stats.modified.toIso8601String(),
              'permissions': stats.mode.toRadixString(8),
            },
          ),
        ],
      );
    },
  );

  // API endpoint template
  server.addResourceTemplate(
    ResourceTemplate(
      uriTemplate: 'api://v1/{endpoint}',
      name: 'API Access',
      description: 'Access API endpoints',
      mimeType: 'application/json',
    ),
    (uri) async {
      final endpoint = uri.replaceFirst('api://v1/', '');
      
      // Simulate API call
      await Future.delayed(const Duration(milliseconds: 500));
      
      final data = {
        'endpoint': endpoint,
        'timestamp': DateTime.now().toIso8601String(),
        'status': 'success',
        'data': {
          'message': 'This is simulated API data for $endpoint',
          'version': '1.0.0',
        },
      };
      
      return ReadResourceResult(
        contents: [
          ResourceContentInfo(
            uri: uri,
            mimeType: 'application/json',
            text: jsonEncode(data),
            annotations: {
              'api_version': '1.0.0',
              'cache_ttl': 300,
            },
          ),
        ],
      );
    },
  );

  print('✅ Resource templates registered successfully');
}

/// Register enhanced prompts with arguments
void _registerEnhancedPrompts(Server server) {
  print('💬 Registering enhanced prompts...');

  // Dynamic prompt with arguments
  server.addPrompt(
    Prompt(
      name: 'code_review',
      description: 'Generate a code review prompt',
      arguments: [
        const PromptArgument(
          name: 'language',
          description: 'Programming language',
          required: true,
        ),
        const PromptArgument(
          name: 'style',
          description: 'Review style (formal/casual)',
          required: false,
        ),
        const PromptArgument(
          name: 'focus',
          description: 'Focus areas (security, performance, readability)',
          required: false,
        ),
      ],
    ),
    (arguments) async {
      final language = arguments['language'] as String;
      final style = arguments['style'] as String? ?? 'professional';
      final focus = arguments['focus'] as String? ?? 'general';
      
      final styleGuide = style == 'formal' 
        ? 'Please provide a formal, detailed code review'
        : 'Please provide a friendly, constructive code review';
        
      final focusGuide = focus == 'security'
        ? 'Focus primarily on security vulnerabilities and best practices.'
        : focus == 'performance'
        ? 'Focus primarily on performance optimizations and efficiency.'
        : focus == 'readability'
        ? 'Focus primarily on code clarity and maintainability.'
        : 'Provide a comprehensive review covering all aspects.';
      
      return GetPromptResult(
        description: 'Code review prompt for $language code',
        messages: [
          Message(
            role: 'system',
            content: TextContent(
              text: '''You are an expert $language developer conducting a code review.

$styleGuide with the following focus:
$focusGuide

Please review the code and provide:
1. Overall assessment
2. Specific issues found
3. Recommendations for improvement
4. Best practices suggestions

Be constructive and educational in your feedback.''',
              annotations: {
                'language': language,
                'style': style,
                'focus': focus,
                'prompt_version': '2.0.0',
              },
            ),
          ),
        ],
      );
    },
  );

  // Multi-modal prompt
  server.addPrompt(
    Prompt(
      name: 'analyze_document',
      description: 'Analyze a document with text and images',
      arguments: [
        const PromptArgument(
          name: 'document_type',
          description: 'Type of document (report, presentation, etc.)',
          required: true,
        ),
        const PromptArgument(
          name: 'analysis_depth',
          description: 'Depth of analysis (shallow, medium, deep)',
          required: false,
        ),
      ],
    ),
    (arguments) async {
      final documentType = arguments['document_type'] as String;
      final depth = arguments['analysis_depth'] as String? ?? 'medium';
      
      return GetPromptResult(
        description: 'Document analysis prompt for $documentType',
        messages: [
          Message(
            role: 'user',
            content: TextContent(
              text: '''Please analyze this $documentType document.

Analysis depth: $depth

Provide insights on:
- Structure and organization
- Content quality and clarity
- Visual elements effectiveness
- Recommendations for improvement''',
              annotations: {
                'document_type': documentType,
                'analysis_depth': depth,
                'supports_multimodal': true,
              },
            ),
          ),
        ],
      );
    },
  );

  print('✅ Enhanced prompts registered successfully');
}

/// Set up OAuth authentication example
void _setupAuthentication(Server server) {
  print('🔐 Setting up authentication examples...');
  
  // In a real implementation, you would:
  // 1. Configure OAuth provider settings
  // 2. Set up token validation
  // 3. Define scopes and permissions
  // 4. Implement authorization middleware
  
  print('ℹ️  Authentication setup would include:');
  print('   - OAuth 2.1 configuration');
  print('   - Token validation endpoints');
  print('   - Scope-based access control');
  print('   - Authorization middleware');
}

/// Configure event handlers for the server
void _setupEventHandlers(Server server) {
  print('📡 Setting up event handlers...');

  // Tool list changes
  server.onToolsChanged(() {
    print('🔧 Tools list updated');
  });

  // Resource list changes
  server.onResourcesChanged(() {
    print('📁 Resources list updated');
  });

  // Prompt list changes
  server.onPromptsChanged(() {
    print('💭 Prompts list updated');
  });

  print('✅ Event handlers configured');
}

/// Start HTTP server with Streamable HTTP transport
Future<void> _startHttpServer(Server server) async {
  print('🌐 Starting Streamable HTTP server...');
  
  try {
    // Create HTTP server
    final httpServer = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
    print('✅ Server listening on http://localhost:8080');
    
    // Handle HTTP requests
    await for (final request in httpServer) {
      _handleHttpRequest(server, request);
    }
  } catch (e) {
    print('❌ Failed to start HTTP server: $e');
    exit(1);
  }
}

/// Handle individual HTTP requests
void _handleHttpRequest(Server server, HttpRequest request) async {
  // Set CORS headers
  request.response.headers.set('Access-Control-Allow-Origin', '*');
  request.response.headers.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
  request.response.headers.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  
  if (request.method == 'OPTIONS') {
    request.response.statusCode = 200;
    await request.response.close();
    return;
  }
  
  if (request.method != 'POST') {
    request.response.statusCode = 405;
    await request.response.close();
    return;
  }
  
  try {
    // Read request body
    final body = await utf8.decoder.bind(request).join();
    final jsonRpcRequest = jsonDecode(body);
    
    print('📨 Received request: ${jsonRpcRequest['method']}');
    
    // Process with server (this is simplified - real implementation would be more complex)
    final response = await _processJsonRpcRequest(server, jsonRpcRequest);
    
    // Send response
    request.response.headers.contentType = ContentType.json;
    request.response.statusCode = 200;
    request.response.write(jsonEncode(response));
    await request.response.close();
    
  } catch (e) {
    // Error response
    request.response.statusCode = 400;
    request.response.write(jsonEncode({
      'jsonrpc': '2.0',
      'error': {
        'code': -32700,
        'message': 'Parse error: $e',
      },
    }));
    await request.response.close();
  }
}

/// Process JSON-RPC request (simplified example)
Future<Map<String, dynamic>> _processJsonRpcRequest(
  Server server, 
  Map<String, dynamic> request,
) async {
  final method = request['method'] as String;
  final id = request['id'];
  
  try {
    switch (method) {
      case 'initialize':
        return {
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': McpProtocol.v2025_03_26,
            'serverInfo': {
              'name': server.name,
              'version': server.version,
            },
            'capabilities': server.capabilities.toJson(),
          },
        };
        
      case 'tools/list':
        final tools = server.getRegisteredTools();
        return {
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'tools': tools.map((tool) => tool.toJson()).toList(),
          },
        };
        
      default:
        return {
          'jsonrpc': '2.0',
          'id': id,
          'error': {
            'code': McpProtocol.errorMethodNotFound,
            'message': 'Method not found: $method',
          },
        };
    }
  } catch (e) {
    return {
      'jsonrpc': '2.0',
      'id': id,
      'error': {
        'code': McpProtocol.errorInternal,
        'message': 'Internal error: $e',
      },
    };
  }
}

/// Get MIME type for file extension
String _getMimeType(String path) {
  final extension = path.split('.').last.toLowerCase();
  
  switch (extension) {
    case 'txt':
      return 'text/plain';
    case 'json':
      return 'application/json';
    case 'html':
      return 'text/html';
    case 'css':
      return 'text/css';
    case 'js':
      return 'application/javascript';
    case 'dart':
      return 'application/dart';
    case 'py':
      return 'text/x-python';
    case 'java':
      return 'text/x-java-source';
    case 'cpp':
    case 'cc':
    case 'cxx':
      return 'text/x-c++src';
    case 'c':
      return 'text/x-csrc';
    case 'h':
      return 'text/x-chdr';
    default:
      return 'application/octet-stream';
  }
}*/
