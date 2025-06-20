/// StreamableHTTP Authentication Tests - Essential Security Verification
/// 
/// Core tests to verify Bearer token authentication works correctly
/// and maintains security compliance with MCP standards.
library;

import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

void main() {
  group('StreamableHTTP Authentication', () {
    late HttpClient httpClient;
    
    setUp(() {
      httpClient = HttpClient();
      httpClient.connectionTimeout = Duration(milliseconds: 100);
    });
    
    tearDown(() async {
      httpClient.close();
      await Future.delayed(Duration(milliseconds: 10));
    });

    test('✅ Valid Bearer token accepted', () async {
      const authToken = 'valid-test-token-123';
      
      final transport = StreamableHttpServerTransport(
        config: StreamableHttpServerConfig(
          port: 8500,
          authToken: authToken,
          isJsonResponseEnabled: true,
        ),
      );
      
      try {
        await transport.start();
        await Future.delayed(Duration(milliseconds: 20));
        
        final request = await httpClient.postUrl(Uri.parse('http://localhost:8500/mcp'));
        request.headers.set('Content-Type', 'application/json');
        request.headers.set('Accept', 'application/json, text/event-stream');
        request.headers.set('Authorization', 'Bearer $authToken');
        request.headers.set('mcp-session-id', 'test-session');
        
        request.write(jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1}));
        final response = await request.close();
        
        // Auth passed (200 or 500 for no server connection)
        expect(response.statusCode, anyOf(equals(200), equals(500)));
        
      } finally {
        transport.close();
        await Future.delayed(Duration(milliseconds: 10));
      }
    });
      
    test('❌ Invalid Bearer token rejected with 401', () async {
      const authToken = 'valid-token-123';
      const invalidToken = 'invalid-token-456';
      
      final transport = StreamableHttpServerTransport(
        config: StreamableHttpServerConfig(
          port: 8501,
          authToken: authToken,
          isJsonResponseEnabled: true,
        ),
      );
      
      try {
        await transport.start();
        await Future.delayed(Duration(milliseconds: 20));
        
        final request = await httpClient.postUrl(Uri.parse('http://localhost:8501/mcp'));
        request.headers.set('Content-Type', 'application/json');
        request.headers.set('Accept', 'application/json, text/event-stream');
        request.headers.set('Authorization', 'Bearer $invalidToken');
        request.headers.set('mcp-session-id', 'test-session');
        
        request.write(jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1}));
        final response = await request.close();
        
        expect(response.statusCode, equals(401));
        
        final responseBody = await utf8.decoder.bind(response).join();
        final responseJson = jsonDecode(responseBody) as Map<String, dynamic>;
        expect(responseJson['error'], contains('Unauthorized'));
        
      } finally {
        transport.close();
        await Future.delayed(Duration(milliseconds: 10));
      }
    });
      
    test('❌ Missing Authorization header rejected with 401', () async {
      const authToken = 'valid-token-123';
      
      final transport = StreamableHttpServerTransport(
        config: StreamableHttpServerConfig(
          port: 8502,
          authToken: authToken,
          isJsonResponseEnabled: true,
        ),
      );
      
      try {
        await transport.start();
        await Future.delayed(Duration(milliseconds: 20));
        
        final request = await httpClient.postUrl(Uri.parse('http://localhost:8502/mcp'));
        request.headers.set('Content-Type', 'application/json');
        request.headers.set('Accept', 'application/json, text/event-stream');
        request.headers.set('mcp-session-id', 'test-session');
        // No Authorization header
        
        request.write(jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1}));
        final response = await request.close();
        
        expect(response.statusCode, equals(401));
        
      } finally {
        transport.close();
        await Future.delayed(Duration(milliseconds: 10));
      }
    });

    test('🔓 Auth disabled mode allows requests', () async {
      final transport = StreamableHttpServerTransport(
        config: StreamableHttpServerConfig(
          port: 8503,
          authToken: null, // Auth disabled
          isJsonResponseEnabled: true,
        ),
      );
      
      try {
        await transport.start();
        await Future.delayed(Duration(milliseconds: 20));
        
        final request = await httpClient.postUrl(Uri.parse('http://localhost:8503/mcp'));
        request.headers.set('Content-Type', 'application/json');
        request.headers.set('Accept', 'application/json, text/event-stream');
        request.headers.set('mcp-session-id', 'test-session');
        // No Authorization header
        
        request.write(jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1}));
        final response = await request.close();
        
        // Should work when auth is disabled
        expect(response.statusCode, anyOf(equals(200), equals(500)));
        
      } finally {
        transport.close();
        await Future.delayed(Duration(milliseconds: 10));
      }
    });

    test('🏭 Factory method supports authToken', () {
      final transportResult = McpServer.createStreamableHttpTransport(
        8504,
        authToken: 'factory-test-token',
        isJsonResponseEnabled: true,
      );
      
      expect(transportResult.isSuccess, isTrue);
      
      final transport = transportResult.get();
      expect(transport.config.authToken, equals('factory-test-token'));
      
      transport.close();
    });

    test('🔒 Security compliance verified', () async {
      // This test verifies that the same token validation logic
      // is applied consistently
      const validToken = 'consistency-token-123';
      const invalidToken = 'wrong-token-456';
      
      final transport = StreamableHttpServerTransport(
        config: StreamableHttpServerConfig(
          port: 8505,
          authToken: validToken,
          isJsonResponseEnabled: true,
        ),
      );
      
      try {
        await transport.start();
        await Future.delayed(Duration(milliseconds: 20));
        
        // Test invalid token
        final request = await httpClient.postUrl(Uri.parse('http://localhost:8505/mcp'));
        request.headers.set('Content-Type', 'application/json');
        request.headers.set('Accept', 'application/json, text/event-stream');
        request.headers.set('Authorization', 'Bearer $invalidToken');
        request.headers.set('mcp-session-id', 'test-session');
        
        request.write(jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1}));
        final response = await request.close();
        
        // Must reject invalid tokens
        expect(response.statusCode, equals(401));
        
        final responseBody = await utf8.decoder.bind(response).join();
        final responseJson = jsonDecode(responseBody) as Map<String, dynamic>;
        expect(responseJson['error'], contains('Unauthorized'));
        expect(responseJson['error'], contains('Bearer token'));
        
      } finally {
        transport.close();
        await Future.delayed(Duration(milliseconds: 10));
      }
    });
  });
}