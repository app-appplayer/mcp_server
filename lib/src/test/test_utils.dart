import 'dart:async';

import '../server/server.dart';
import '../transport/transport.dart';

/// Mock message handler for testing
class MockMessageHandler {
  final ServerInterface server;

  MockMessageHandler(this.server);

  Future<Map<String, dynamic>> processRequest(
      String method, Map<String, dynamic>? params) async {
    final completer = Completer<Map<String, dynamic>>();
    //final sessionId = 'test-session';
    final requestId = 1;

    // Create mock transport that captures the response
    final mockTransport = MockTransport(onSendCallback: (dynamic response) {
      if (response is Map<String, dynamic> && response['id'] == requestId) {
        completer.complete(response);
      }
    });

    // Add transport to server
    (server as Server).connect(mockTransport);

    // Send message
    mockTransport.receiveMessage({
      'jsonrpc': '2.0',
      'id': requestId,
      'method': method,
      'params': params,
    });

    return completer.future;
  }

  Future<Map<String, dynamic>> handleInitialize() async {
    return processRequest('initialize', {
      'protocolVersion': '2024-11-05',
      'capabilities': {},
    });
  }

  Future<Map<String, dynamic>> listTools() async {
    return processRequest('tools/list', {});
  }

  Future<Map<String, dynamic>> callTool(String name, Map<String, dynamic> arguments) async {
    return processRequest('tools/call', {
      'name': name,
      'arguments': arguments,
    });
  }

  Future<Map<String, dynamic>> listResources() async {
    return processRequest('resources/list', {});
  }

  Future<Map<String, dynamic>> readResource(String uri, {Map<String, dynamic>? params}) async {
    final Map<String, dynamic> requestParams = {'uri': uri};
    if (params != null) {
      requestParams.addAll(params);
    }
    return processRequest('resources/read', requestParams);
  }

  Future<Map<String, dynamic>> listPrompts() async {
    return processRequest('prompts/list', {});
  }

  Future<Map<String, dynamic>> getPrompt(String name, {Map<String, dynamic>? arguments}) async {
    return processRequest('prompts/get', {
      'name': name,
      'arguments': arguments,
    });
  }

  Future<Map<String, dynamic>> healthCheck() async {
    return processRequest('health/check', {});
  }

  Future<Map<String, dynamic>> cancel(String operationId) async {
    return processRequest('cancel', {
      'id': operationId,
    });
  }
}