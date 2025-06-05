import 'dart:async';
// import 'dart:convert'; // unused

import 'package:mcp_server/mcp_server.dart';
import 'package:test/test.dart';

// Mock transport for testing
class MockServerTransport implements ServerTransport {
  final StreamController<dynamic> _messageController = StreamController<dynamic>.broadcast();
  final List<dynamic> sentMessages = [];
  bool _closed = false;

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;
  
  final Completer<void> _closeCompleter = Completer<void>();

  @override
  void send(dynamic message) {
    if (!_closed) {
      sentMessages.add(message);
    }
  }

  @override
  void close() {
    if (!_closed) {
      _closed = true;
      _messageController.close();
      if (!_closeCompleter.isCompleted) {
        _closeCompleter.complete();
      }
    }
  }

  void simulateMessage(dynamic message) {
    if (!_closed) {
      _messageController.add(message);
    }
  }

  dynamic getLastSentMessage() {
    return sentMessages.isNotEmpty ? sentMessages.last : null;
  }

  List<dynamic> getAllSentMessages() {
    return List.unmodifiable(sentMessages);
  }

  void clearSentMessages() {
    sentMessages.clear();
  }
}

void main() {
  group('MCP Server 2025-03-26 JSON-RPC Batch Tests', () {
    late Server server;
    late MockServerTransport transport;

    setUp(() {
      server = Server(
        name: 'Test Batch Server',
        version: '1.0.0',
        capabilities: ServerCapabilities.simple(
          tools: true,
          resources: true,
        ),
      );
      
      transport = MockServerTransport();
      
      // Add some test tools
      server.addTool(
        name: 'echo',
        description: 'Echo the input',
        inputSchema: {
          'type': 'object',
          'properties': {
            'message': {'type': 'string'}
          },
          'required': ['message']
        },
        handler: (args) async {
          return CallToolResult(content: [
            TextContent(text: 'Echo: ${args['message']}')
          ]);
        },
      );
      
      server.addTool(
        name: 'add',
        description: 'Add two numbers',
        inputSchema: {
          'type': 'object',
          'properties': {
            'a': {'type': 'number'},
            'b': {'type': 'number'}
          },
          'required': ['a', 'b']
        },
        handler: (args) async {
          final a = args['a'] as num;
          final b = args['b'] as num;
          return CallToolResult(content: [
            TextContent(text: 'Result: ${a + b}')
          ]);
        },
      );
      
      server.connect(transport);
    });

    tearDown(() {
      server.dispose();
      transport.close();
    });

    group('Batch Request Processing', () {
      test('Empty batch request returns error', () async {
        // Send initialize first
        transport.simulateMessage({
          'jsonrpc': '2.0',
          'id': 'init',
          'method': 'initialize',
          'params': {
            'protocolVersion': '2025-03-26',
            'capabilities': {},
            'clientInfo': {'name': 'Test Client', 'version': '1.0.0'}
          }
        });
        
        await Future.delayed(Duration(milliseconds: 10));
        transport.clearSentMessages();
        
        // Send empty batch
        transport.simulateMessage([]);
        
        await Future.delayed(Duration(milliseconds: 50));
        
        final messages = transport.getAllSentMessages();
        expect(messages, isNotEmpty);
        
        final errorMessage = messages.last;
        expect(errorMessage['error'], isNotNull);
        expect(errorMessage['error']['message'], contains('Empty batch request'));
      });
      
      test('Mixed valid and invalid requests in batch', () async {
        // Send initialize first
        transport.simulateMessage({
          'jsonrpc': '2.0',
          'id': 'init',
          'method': 'initialize',
          'params': {
            'protocolVersion': '2025-03-26',
            'capabilities': {},
            'clientInfo': {'name': 'Test Client', 'version': '1.0.0'}
          }
        });
        
        await Future.delayed(Duration(milliseconds: 10));
        transport.clearSentMessages();
        
        // Send batch with mixed requests
        final batchRequest = [
          {
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {
              'name': 'echo',
              'arguments': {'message': 'Hello'}
            }
          },
          {
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'invalid/method',
            'params': {}
          },
          {
            'jsonrpc': '2.0',
            'id': 3,
            'method': 'tools/call',
            'params': {
              'name': 'add',
              'arguments': {'a': 5, 'b': 3}
            }
          },
          // Invalid request (not an object)
          'invalid-request',
        ];
        
        transport.simulateMessage(batchRequest);
        
        await Future.delayed(Duration(milliseconds: 100));
        
        final messages = transport.getAllSentMessages();
        expect(messages, isNotEmpty);
        
        // Should get responses for the batch
        expect(messages, isNotEmpty);
        
        // Check if we got at least some responses
        final hasResponses = messages.any((msg) => msg is List || msg['result'] != null || msg['error'] != null);
        expect(hasResponses, isTrue, reason: 'Should receive batch responses');
      });
      
      test('Batch with only notifications', () async {
        // Send initialize first
        transport.simulateMessage({
          'jsonrpc': '2.0',
          'id': 'init',
          'method': 'initialize',
          'params': {
            'protocolVersion': '2025-03-26',
            'capabilities': {},
            'clientInfo': {'name': 'Test Client', 'version': '1.0.0'}
          }
        });
        
        await Future.delayed(Duration(milliseconds: 10));
        transport.clearSentMessages();
        
        // Send batch with only notifications (no id field)
        final batchRequest = [
          {
            'jsonrpc': '2.0',
            'method': 'notifications/initialized'
          },
          {
            'jsonrpc': '2.0',
            'method': 'client/ready'
          },
        ];
        
        transport.simulateMessage(batchRequest);
        
        await Future.delayed(Duration(milliseconds: 50));
        
        // Should not send any response for notifications-only batch
        final messages = transport.getAllSentMessages();
        // Only the initialize response should be present
        expect(messages.length, lessThanOrEqualTo(1));
      });
      
      test('Large batch request processing', () async {
        // Send initialize first
        transport.simulateMessage({
          'jsonrpc': '2.0',
          'id': 'init',
          'method': 'initialize',
          'params': {
            'protocolVersion': '2025-03-26',
            'capabilities': {},
            'clientInfo': {'name': 'Test Client', 'version': '1.0.0'}
          }
        });
        
        await Future.delayed(Duration(milliseconds: 10));
        transport.clearSentMessages();
        
        // Create a large batch request
        final batchRequest = <Map<String, dynamic>>[];
        for (int i = 0; i < 20; i++) {
          batchRequest.add({
            'jsonrpc': '2.0',
            'id': i + 1,
            'method': 'tools/call',
            'params': {
              'name': 'echo',
              'arguments': {'message': 'Message $i'}
            }
          });
        }
        
        transport.simulateMessage(batchRequest);
        
        await Future.delayed(Duration(milliseconds: 200));
        
        final messages = transport.getAllSentMessages();
        expect(messages, isNotEmpty);
        
        // Should get responses for large batch
        final hasResponses = messages.any((msg) => msg is List || msg['result'] != null);
        expect(hasResponses, isTrue, reason: 'Should receive responses for large batch');
      });
    });

    group('Batch Request Tracker', () {
      test('BatchRequestTracker correctly tracks completion', () {
        final tracker = BatchRequestTracker(
          batchId: 'test-batch',
          totalRequests: 3,
        );
        
        expect(tracker.isComplete, isFalse);
        expect(tracker.getBatchResponse(), isEmpty);
        
        // Add first response
        tracker.addResponse(1, {
          'jsonrpc': '2.0',
          'id': 1,
          'result': {'success': true}
        });
        
        expect(tracker.isComplete, isFalse);
        expect(tracker.getBatchResponse(), hasLength(1));
        
        // Add second response
        tracker.addResponse(2, {
          'jsonrpc': '2.0',
          'id': 2,
          'error': {'code': -32601, 'message': 'Method not found'}
        });
        
        expect(tracker.isComplete, isFalse);
        expect(tracker.getBatchResponse(), hasLength(2));
        
        // Add third response
        tracker.addResponse(3, {
          'jsonrpc': '2.0',
          'id': 3,
          'result': {'data': 'test'}
        });
        
        expect(tracker.isComplete, isTrue);
        expect(tracker.getBatchResponse(), hasLength(3));
      });
      
      test('BatchRequestTracker handles duplicate responses', () {
        final tracker = BatchRequestTracker(
          batchId: 'test-batch',
          totalRequests: 2,
        );
        
        final response = {
          'jsonrpc': '2.0',
          'id': 1,
          'result': {'success': true}
        };
        
        // Add same response twice
        tracker.addResponse(1, response);
        tracker.addResponse(1, response);
        
        // Should only have one response
        expect(tracker.getBatchResponse(), hasLength(1));
      });
      
      test('BatchRequestTracker handles null IDs', () {
        final tracker = BatchRequestTracker(
          batchId: 'test-batch',
          totalRequests: 1,
        );
        
        // Add response with null ID (notification)
        tracker.addResponse(null, {
          'jsonrpc': '2.0',
          'method': 'notification'
        });
        
        // Should not add responses with null IDs
        expect(tracker.getBatchResponse(), isEmpty);
        expect(tracker.isComplete, isFalse);
      });
    });
  });
}