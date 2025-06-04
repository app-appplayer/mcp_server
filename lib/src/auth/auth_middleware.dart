/// Authentication middleware for MCP HTTP transport
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:meta/meta.dart';

import '../protocol/protocol.dart';

/// Authentication result
@immutable
class AuthResult {
  /// Whether authentication was successful
  final bool isAuthenticated;
  
  /// Authenticated user information
  final Map<String, dynamic>? userInfo;
  
  /// Error message if authentication failed
  final String? error;
  
  /// Required scopes that were validated
  final List<String>? validatedScopes;
  
  const AuthResult({
    required this.isAuthenticated,
    this.userInfo,
    this.error,
    this.validatedScopes,
  });
  
  /// Create successful authentication result
  const AuthResult.success({
    required Map<String, dynamic> userInfo,
    List<String>? validatedScopes,
  }) : isAuthenticated = true,
       userInfo = userInfo,
       validatedScopes = validatedScopes,
       error = null;
  
  /// Create failed authentication result
  const AuthResult.failure({
    required String error,
  }) : isAuthenticated = false,
       userInfo = null,
       validatedScopes = null,
       error = error;
}

/// Token validation interface
abstract class TokenValidator {
  /// Validate a bearer token
  Future<AuthResult> validateToken(String token, {List<String>? requiredScopes});
  
  /// Validate token introspection (RFC7662)
  Future<Map<String, dynamic>> introspectToken(String token);
  
  /// Check if token has required scopes
  bool hasRequiredScopes(List<String> tokenScopes, List<String> requiredScopes);
}

/// OAuth 2.1 token validator
class OAuthTokenValidator implements TokenValidator {
  final String introspectionEndpoint;
  final String clientId;
  final String clientSecret;
  final HttpClient _httpClient;
  
  OAuthTokenValidator({
    required this.introspectionEndpoint,
    required this.clientId,
    required this.clientSecret,
  }) : _httpClient = HttpClient();
  
  @override
  Future<AuthResult> validateToken(String token, {List<String>? requiredScopes}) async {
    try {
      final introspection = await introspectToken(token);
      
      // Check if token is active
      if (introspection['active'] != true) {
        return const AuthResult.failure(error: 'Token is not active');
      }
      
      // Check scopes if required
      if (requiredScopes != null && requiredScopes.isNotEmpty) {
        final tokenScopes = (introspection['scope'] as String?)?.split(' ') ?? [];
        if (!hasRequiredScopes(tokenScopes, requiredScopes)) {
          return AuthResult.failure(
            error: 'Insufficient scopes. Required: ${requiredScopes.join(', ')}, '
                   'Available: ${tokenScopes.join(', ')}'
          );
        }
      }
      
      return AuthResult.success(
        userInfo: {
          'sub': introspection['sub'],
          'client_id': introspection['client_id'],
          'username': introspection['username'],
          'scope': introspection['scope'],
          'exp': introspection['exp'],
          'iat': introspection['iat'],
        },
        validatedScopes: requiredScopes,
      );
      
    } catch (e) {
      return AuthResult.failure(error: 'Token validation failed: $e');
    }
  }
  
  @override
  Future<Map<String, dynamic>> introspectToken(String token) async {
    final request = await _httpClient.postUrl(Uri.parse(introspectionEndpoint));
    
    // Add authorization header
    final credentials = base64Encode(utf8.encode('$clientId:$clientSecret'));
    request.headers.set('Authorization', 'Basic $credentials');
    request.headers.set('Content-Type', 'application/x-www-form-urlencoded');
    
    // Add token to body
    request.write('token=$token');
    
    final response = await request.close();
    final responseBody = await utf8.decoder.bind(response).join();
    
    if (response.statusCode != 200) {
      throw HttpException('Token introspection failed: ${response.statusCode}');
    }
    
    return jsonDecode(responseBody) as Map<String, dynamic>;
  }
  
  @override
  bool hasRequiredScopes(List<String> tokenScopes, List<String> requiredScopes) {
    return requiredScopes.every((scope) => tokenScopes.contains(scope));
  }
  
  void close() {
    _httpClient.close();
  }
}

/// Simple API key validator
class ApiKeyValidator implements TokenValidator {
  final Map<String, Map<String, dynamic>> _validApiKeys;
  
  ApiKeyValidator(this._validApiKeys);
  
  @override
  Future<AuthResult> validateToken(String token, {List<String>? requiredScopes}) async {
    final keyInfo = _validApiKeys[token];
    
    if (keyInfo == null) {
      return const AuthResult.failure(error: 'Invalid API key');
    }
    
    // Check if key is expired
    final exp = keyInfo['exp'] as int?;
    if (exp != null && DateTime.now().millisecondsSinceEpoch > exp * 1000) {
      return const AuthResult.failure(error: 'API key expired');
    }
    
    // Check scopes
    if (requiredScopes != null && requiredScopes.isNotEmpty) {
      final keyScopes = (keyInfo['scopes'] as List<dynamic>?)?.cast<String>() ?? [];
      if (!hasRequiredScopes(keyScopes, requiredScopes)) {
        return AuthResult.failure(
          error: 'Insufficient scopes for API key'
        );
      }
    }
    
    return AuthResult.success(
      userInfo: keyInfo,
      validatedScopes: requiredScopes,
    );
  }
  
  @override
  Future<Map<String, dynamic>> introspectToken(String token) async {
    final keyInfo = _validApiKeys[token];
    if (keyInfo == null) {
      return {'active': false};
    }
    
    return {
      'active': true,
      ...keyInfo,
    };
  }
  
  @override
  bool hasRequiredScopes(List<String> tokenScopes, List<String> requiredScopes) {
    return requiredScopes.every((scope) => tokenScopes.contains(scope));
  }
}

/// Authentication middleware for HTTP requests
class AuthMiddleware {
  final TokenValidator validator;
  final List<String> publicPaths;
  final List<String> defaultRequiredScopes;
  final bool strictMode;
  
  AuthMiddleware({
    required this.validator,
    this.publicPaths = const ['/health', '/ping'],
    this.defaultRequiredScopes = const [],
    this.strictMode = true,
  });
  
  /// Process HTTP request authentication
  Future<AuthResult?> authenticate(
    HttpRequest request, {
    List<String>? requiredScopes,
  }) async {
    // Skip authentication for public paths
    if (publicPaths.contains(request.uri.path)) {
      return const AuthResult.success(userInfo: {'public': true});
    }
    
    // Extract token from Authorization header
    final authHeader = request.headers.value('Authorization');
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      if (strictMode) {
        return const AuthResult.failure(error: 'Missing or invalid Authorization header');
      }
      return null; // Allow unauthenticated access in non-strict mode
    }
    
    final token = authHeader.substring(7); // Remove "Bearer " prefix
    final scopes = requiredScopes ?? defaultRequiredScopes;
    
    return await validator.validateToken(token, requiredScopes: scopes);
  }
  
  /// Send authentication challenge response
  void sendAuthChallenge(HttpRequest request, {String? error, String? errorDescription}) {
    request.response.statusCode = 401;
    
    String challenge = 'Bearer';
    if (error != null) {
      challenge += ' error="$error"';
      if (errorDescription != null) {
        challenge += ', error_description="$errorDescription"';
      }
    }
    
    request.response.headers.set('WWW-Authenticate', challenge);
    request.response.headers.set('Content-Type', 'application/json');
    
    final errorResponse = {
      'error': error ?? 'unauthorized',
      'error_description': errorDescription ?? 'Authentication required',
    };
    
    request.response.write(jsonEncode(errorResponse));
  }
  
  /// Send forbidden response
  void sendForbidden(HttpRequest request, {String? reason}) {
    request.response.statusCode = 403;
    request.response.headers.set('Content-Type', 'application/json');
    
    final errorResponse = {
      'error': 'forbidden',
      'error_description': reason ?? 'Insufficient permissions',
    };
    
    request.response.write(jsonEncode(errorResponse));
  }
}

/// MCP method authorization configuration
class McpMethodAuth {
  /// Methods that require authentication
  static const Set<String> authenticatedMethods = {
    McpProtocol.methodListTools,
    McpProtocol.methodCallTool,
    McpProtocol.methodListResources,
    McpProtocol.methodReadResource,
    McpProtocol.methodListPrompts,
    McpProtocol.methodGetPrompt,
    McpProtocol.methodComplete,
  };
  
  /// Methods that require specific scopes
  static const Map<String, List<String>> methodScopes = {
    McpProtocol.methodCallTool: ['tools:execute'],
    McpProtocol.methodListTools: ['tools:read'],
    McpProtocol.methodListResources: ['resources:read'],
    McpProtocol.methodReadResource: ['resources:read'],
    McpProtocol.methodListPrompts: ['prompts:read'],
    McpProtocol.methodGetPrompt: ['prompts:read'],
    McpProtocol.methodComplete: ['completion:create'],
  };
  
  /// Get required scopes for a method
  static List<String> getRequiredScopes(String method) {
    return methodScopes[method] ?? [];
  }
  
  /// Check if method requires authentication
  static bool requiresAuth(String method) {
    return authenticatedMethods.contains(method);
  }
}

/// Authorization context for MCP requests
@immutable
class AuthContext {
  /// Authenticated user information
  final Map<String, dynamic> userInfo;
  
  /// Validated scopes for this request
  final List<String> scopes;
  
  /// Original authentication token
  final String? token;
  
  /// Request timestamp
  final DateTime timestamp;
  
  const AuthContext({
    required this.userInfo,
    this.scopes = const [],
    this.token,
    required this.timestamp,
  });
  
  /// Get user ID
  String? get userId => userInfo['sub'] as String?;
  
  /// Get username
  String? get username => userInfo['username'] as String?;
  
  /// Get client ID
  String? get clientId => userInfo['client_id'] as String?;
  
  /// Check if context has specific scope
  bool hasScope(String scope) => scopes.contains(scope);
  
  /// Check if context has all required scopes
  bool hasScopes(List<String> requiredScopes) {
    return requiredScopes.every((scope) => scopes.contains(scope));
  }
  
  /// Convert to JSON for logging/debugging
  Map<String, dynamic> toJson() => {
    'userId': userId,
    'username': username,
    'clientId': clientId,
    'scopes': scopes,
    'timestamp': timestamp.toIso8601String(),
  };
}