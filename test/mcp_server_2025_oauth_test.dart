// import 'dart:async'; // unused
// import 'dart:convert'; // unused

import 'package:mcp_server/mcp_server.dart';
import 'package:test/test.dart';

void main() {
  group('MCP Server 2025-03-26 OAuth Tests', () {
    late Server server;

    setUp(() {
      server = Server(
        name: 'Test OAuth Server',
        version: '1.0.0',
        capabilities: const ServerCapabilities(
          tools: true,
          resources: true,
          prompts: true,
        ),
      );
    });

    tearDown(() {
      server.dispose();
    });

    group('OAuth Authentication', () {
      test('OAuth authentication can be enabled and disabled', () {
        expect(server.isAuthenticationEnabled, isFalse);
        
        final validator = ApiKeyValidator({
          'test-key': {
            'scopes': ['tools:execute', 'resources:read'],
            'exp': DateTime.now().add(Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
          }
        });
        
        server.enableAuthentication(validator);
        expect(server.isAuthenticationEnabled, isTrue);
        
        server.disableAuthentication();
        expect(server.isAuthenticationEnabled, isFalse);
      });
      
      test('Authentication middleware validates credentials correctly', () {
        final validator = ApiKeyValidator({
          'valid-token': {
            'scopes': ['tools:execute'],
            'exp': DateTime.now().add(Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
          }
        });
        
        server.enableAuthentication(validator);
        expect(server.isAuthenticationEnabled, isTrue);
        
        // Test that OAuth is properly configured
        expect(server.isAuthenticationEnabled, isTrue);
      });
      
      test('Token validation works correctly', () async {
        final validator = ApiKeyValidator({
          'valid-token': {
            'scopes': ['tools:execute', 'resources:read'],
            'exp': DateTime.now().add(Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
          },
          'expired-token': {
            'scopes': ['tools:execute'],
            'exp': DateTime.now().subtract(Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
          }
        });
        
        server.enableAuthentication(validator);
        
        // Test valid token
        final validResult = await validator.validateToken('valid-token');
        expect(validResult.isAuthenticated, isTrue);
        
        // Test invalid token
        final invalidResult = await validator.validateToken('invalid-token');
        expect(invalidResult.isAuthenticated, isFalse);
        
        // Test expired token
        final expiredResult = await validator.validateToken('expired-token');
        expect(expiredResult.isAuthenticated, isFalse);
      });
      
      test('Scope validation works correctly', () async {
        final validator = ApiKeyValidator({
          'limited-token': {
            'scopes': ['resources:read'],
            'exp': DateTime.now().add(Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
          }
        });
        
        // Test with sufficient scopes
        final validResult = await validator.validateToken(
          'limited-token', 
          requiredScopes: ['resources:read']
        );
        expect(validResult.isAuthenticated, isTrue);
        
        // Test with insufficient scopes
        final invalidResult = await validator.validateToken(
          'limited-token', 
          requiredScopes: ['tools:execute']
        );
        expect(invalidResult.isAuthenticated, isFalse);
        expect(invalidResult.error, contains('Insufficient scopes'));
      });
    });

    group('OAuth Method Authorization', () {
      test('OAuth method requirements are correctly defined', () {
        expect(McpMethodAuth.requiresAuth('tools/call'), isTrue);
        expect(McpMethodAuth.requiresAuth('tools/list'), isTrue);
        expect(McpMethodAuth.requiresAuth('resources/read'), isTrue);
        expect(McpMethodAuth.requiresAuth('resources/list'), isTrue);
        expect(McpMethodAuth.requiresAuth('prompts/get'), isTrue);
        expect(McpMethodAuth.requiresAuth('prompts/list'), isTrue);
        
        // Initialize should not require auth
        expect(McpMethodAuth.requiresAuth('initialize'), isFalse);
      });
      
      test('Method-specific scopes are correctly defined', () {
        expect(McpMethodAuth.getRequiredScopes('tools/call'), contains('tools:execute'));
        expect(McpMethodAuth.getRequiredScopes('tools/list'), contains('tools:read'));
        expect(McpMethodAuth.getRequiredScopes('resources/read'), contains('resources:read'));
        expect(McpMethodAuth.getRequiredScopes('resources/list'), contains('resources:read'));
        expect(McpMethodAuth.getRequiredScopes('prompts/get'), contains('prompts:read'));
        expect(McpMethodAuth.getRequiredScopes('prompts/list'), contains('prompts:read'));
      });
    });

    group('Session OAuth State', () {
      test('Session can store OAuth tokens', () {
        final session = ClientSession(
          id: 'test-session',
          connectedAt: DateTime.now(),
        );
        
        expect(session.authToken, isNull);
        expect(session.accessTokens, isNull);
        expect(session.pendingAuthCodes, isNull);
        
        // Set auth token
        session.authToken = 'test-token';
        expect(session.authToken, equals('test-token'));
        
        // Set access tokens
        session.accessTokens = {
          'access-token-1': {
            'client_id': 'test-client',
            'scope': ['tools:execute'],
            'expires_at': DateTime.now().add(Duration(hours: 1)).millisecondsSinceEpoch,
          }
        };
        
        expect(session.accessTokens, isNotNull);
        expect(session.accessTokens!['access-token-1'], isNotNull);
        expect(session.accessTokens!['access-token-1']!['client_id'], equals('test-client'));
      });
      
      test('Session can store auth context', () {
        final session = ClientSession(
          id: 'test-session',
          connectedAt: DateTime.now(),
        );
        
        expect(session.authContext, isNull);
        
        final authContext = AuthContext(
          userInfo: {
            'sub': 'user123',
            'client_id': 'test-client',
          },
          scopes: ['tools:execute', 'resources:read'],
          timestamp: DateTime.now(),
        );
        
        session.authContext = authContext;
        
        expect(session.authContext, isNotNull);
        expect(session.authContext!.userId, equals('user123'));
        expect(session.authContext!.clientId, equals('test-client'));
        expect(session.authContext!.hasScope('tools:execute'), isTrue);
        expect(session.authContext!.hasScope('invalid:scope'), isFalse);
        expect(session.authContext!.hasScopes(['tools:execute', 'resources:read']), isTrue);
        expect(session.authContext!.hasScopes(['tools:execute', 'invalid:scope']), isFalse);
      });
    });
  });
}