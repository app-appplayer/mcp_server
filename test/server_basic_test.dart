import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';
import 'package:mcp_server/src/middleware/rate_limiter.dart';
import 'package:mcp_server/src/middleware/compression.dart';
// import 'package:mcp_server/src/transport/websocket_transport.dart'; // unnecessary
// import 'package:mcp_server/src/transport/connection_manager.dart'; // unnecessary
import 'dart:async';

void main() {
  group('Basic Server Tests', () {
    late Server server;
    
    setUp(() {
      server = Server(
        name: 'test-server',
        version: '1.0.0',
        capabilities: ServerCapabilities(
          tools: true,
          resources: true,
          prompts: true,
        ),
      );
    });
    
    tearDown(() {
      server.dispose();
    });
    
    test('Server creation and properties', () {
      expect(server.name, equals('test-server'));
      expect(server.version, equals('1.0.0'));
      expect(server.capabilities.tools, isTrue);
      expect(server.capabilities.resources, isTrue);
      expect(server.capabilities.prompts, isTrue);
      expect(server.isConnected, isFalse);
    });
    
    test('Add and get tools', () {
      server.addTool(
        name: 'test-tool',
        description: 'A test tool',
        inputSchema: {
          'type': 'object',
          'properties': {
            'input': {'type': 'string'},
          },
        },
        handler: (args) async {
          return CallToolResult(
            content: [TextContent(text: 'Tool executed')],
          );
        },
      );
      
      final tools = server.getTools();
      expect(tools.length, equals(1));
      expect(tools.first.name, equals('test-tool'));
      expect(tools.first.description, equals('A test tool'));
    });
    
    test('Add and get resources', () {
      server.addResource(
        uri: 'test://resource',
        name: 'Test Resource',
        description: 'A test resource',
        mimeType: 'text/plain',
        handler: (uri, params) async {
          return ReadResourceResult(
            contents: [
              ResourceContentInfo(
                uri: uri,
                mimeType: 'text/plain',
                text: 'Resource content',
              ),
            ],
          );
        },
      );
      
      final resources = server.getResources();
      expect(resources.length, equals(1));
      expect(resources.first.uri, equals('test://resource'));
      expect(resources.first.name, equals('Test Resource'));
    });
    
    test('Add and get prompts', () {
      server.addPrompt(
        name: 'test-prompt',
        description: 'A test prompt',
        arguments: [
          PromptArgument(
            name: 'message',
            description: 'The message',
            required: true,
          ),
        ],
        handler: (args) async {
          return GetPromptResult(
            description: 'Generated prompt',
            messages: [
              Message(
                role: 'user',
                content: TextContent(text: args['message'] ?? ''),
              ),
            ],
          );
        },
      );
      
      final prompts = server.getPrompts();
      expect(prompts.length, equals(1));
      expect(prompts.first.name, equals('test-prompt'));
      expect(prompts.first.arguments.length, equals(1));
    });
    
    test('Root management', () {
      expect(server.listRoots(), isEmpty);
      
      server.addRoot(Root(
        uri: '/home/test',
        name: 'Test Root',
        description: 'A test root directory',
      ));
      
      final roots = server.listRoots();
      expect(roots.length, equals(1));
      expect(roots.first.uri, equals('/home/test'));
      
      server.removeRoot('/home/test');
      expect(server.listRoots(), isEmpty);
    });
    
    test('Rate limiting', () {
      server.enableRateLimiting(
        defaultConfig: RateLimitConfig(
          maxRequests: 10,
          windowDuration: Duration(minutes: 1),
        ),
      );
      
      final stats = server.getRateLimitStats();
      expect(stats['enabled'], isTrue);
      
      server.disableRateLimiting();
      final disabledStats = server.getRateLimitStats();
      expect(disabledStats['enabled'], isFalse);
    });
    
    test('Metrics collection', () {
      final metrics = server.getMetrics();
      expect(metrics['metrics'], isA<Map>());
      expect(metrics['startTime'], isA<String>());
      expect(metrics['uptime'], isA<int>());
    });
    
    test('Event streams', () async {
      // Test tool change events
      final toolChanges = <void>[];
      final sub = server.onToolsChanged.listen((_) {
        toolChanges.add(null);
      });
      
      server.addTool(
        name: 'event-test-tool',
        description: 'Tool for event test',
        inputSchema: {},
        handler: (_) async => CallToolResult(content: []),
      );
      
      await Future.delayed(Duration(milliseconds: 10));
      expect(toolChanges.length, equals(1));
      
      server.removeTool('event-test-tool');
      await Future.delayed(Duration(milliseconds: 10));
      expect(toolChanges.length, equals(2));
      
      await sub.cancel();
    });
    
    test('Call tool directly', () async {
      server.addTool(
        name: 'direct-call-tool',
        description: 'Tool for direct call',
        inputSchema: {
          'type': 'object',
          'properties': {
            'text': {'type': 'string'},
          },
        },
        handler: (args) async {
          return CallToolResult(
            content: [
              TextContent(text: 'Echo: ${args['text']}'),
            ],
          );
        },
      );
      
      final result = await server.callTool('direct-call-tool', {'text': 'Hello'});
      expect(result.content.length, equals(1));
      expect((result.content.first as TextContent).text, equals('Echo: Hello'));
    });
    
    test('Read resource directly', () async {
      server.addResource(
        uri: 'test://direct',
        name: 'Direct Resource',
        description: 'Resource for direct read',
        mimeType: 'text/plain',
        handler: (uri, params) async {
          return ReadResourceResult(
            contents: [
              ResourceContentInfo(
                uri: uri,
                mimeType: 'text/plain',
                text: 'Direct content',
              ),
            ],
          );
        },
      );
      
      final result = await server.readResource('test://direct');
      expect(result.contents.length, equals(1));
      expect(result.contents.first.text, equals('Direct content'));
    });
    
    test('Server health', () {
      final health = server.getHealth();
      expect(health.isRunning, isFalse); // Not connected
      expect(health.connectedSessions, equals(0));
      expect(health.registeredTools, greaterThanOrEqualTo(0));
      expect(health.startTime, isA<DateTime>());
      expect(health.uptime, isA<Duration>());
    });
  });
  
  group('Transport Tests', () {
    test('StdioServerTransport singleton', () {
      final transport1 = StdioServerTransport();
      final transport2 = StdioServerTransport();
      expect(identical(transport1, transport2), isTrue);
      transport1.close();
    });
    
    test('WebSocket transport creation', () {
      final config = WebSocketConfig(
        port: 8080,
        path: '/ws',
        pingInterval: Duration(seconds: 30),
      );
      
      final transport = WebSocketServerTransport(config: config);
      expect(transport.onMessage, isA<Stream>());
      expect(transport.onClose, isA<Future>());
      transport.close();
    });
    
    test('Compression middleware', () {
      final compression = CompressionMiddleware();
      final data = List.generate(2048, (i) => i % 256); // 2KB of data
      
      final compressed = compression.compress(data, 'application/json');
      expect(compressed, isNotNull);
      expect(compressed!.compressedSize, lessThan(compressed.originalSize));
      expect(compressed.worthCompressing, isTrue);
      
      final decompressed = compression.decompress(
        compressed.data, 
        compressed.type,
      );
      expect(decompressed, equals(data));
    });
    
    test('Connection manager retry logic', () async {
      int attempts = 0;
      final manager = ConnectionManager<String>(
        name: 'test-connection',
        connectFunction: () async {
          attempts++;
          if (attempts < 3) {
            throw Exception('Connection failed');
          }
          return 'connected';
        },
        onConnected: (conn) {
          expect(conn, equals('connected'));
        },
        onError: (error) {
          // Expected errors during retry
        },
        config: RetryConfig(
          initialDelay: Duration(milliseconds: 10),
          maxDelay: Duration(milliseconds: 100),
          backoffFactor: 2.0,
        ),
      );
      
      await manager.connect();
      await Future.delayed(Duration(milliseconds: 200));
      
      expect(attempts, equals(3));
      expect(manager.isConnected, isTrue);
      manager.dispose();
    });
  });
}