/// Comprehensive MCP 2025-03-26 server example showcasing all new features
/// 
/// TODO: This example has been simplified to work with the current API.
/// Many advanced features are commented out and need to be rewritten.
library;

import 'dart:async';
import 'package:mcp_server/mcp_server.dart';

void main() async {
  // Initialize server with basic capabilities
  await runSimpleMcpServer();
}

/// Simplified MCP server implementation that works with current API
Future<void> runSimpleMcpServer() async {
  print('🚀 Starting Simplified MCP Server...');

  // Create server with basic capabilities
  final server = Server(
    name: 'MCP 2025 Enhanced Server',
    version: '1.0.0',
    capabilities: const ServerCapabilities(
      tools: true,
      toolsListChanged: true,
      resources: true,
      resourcesListChanged: true,
      prompts: true,
      promptsListChanged: true,
      sampling: true,
    ),
  );

  // Register basic tools
  _registerBasicTools(server);

  // Connect to STDIO transport
  final transportResult = McpServer.createStdioTransport();
  final transport = transportResult.get();
  server.connect(transport);

  print('✅ Server started successfully');
  await transport.onClose;
}

/// Register basic tools that work with current API
void _registerBasicTools(Server server) {
  print('📝 Registering basic tools...');

  // Simple echo tool
  server.addTool(
    name: 'echo',
    description: 'Echo back the input',
    inputSchema: {
      'type': 'object',
      'properties': {
        'message': {'type': 'string'}
      },
    },
    handler: (arguments) async {
      final message = arguments['message'] as String? ?? 'No message';
      return CallToolResult(
        content: [TextContent(text: 'Echo: $message')],
      );
    },
  );

  print('✅ Basic tools registered');
}

// TODO: The following functions need major API updates and are commented out

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
