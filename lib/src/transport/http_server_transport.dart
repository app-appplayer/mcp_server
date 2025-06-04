/// HTTP Server Transport for MCP 2025-03-26
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:meta/meta.dart';

import '../../logger.dart';
import '../middleware/compression.dart';
import 'transport.dart';

final Logger _logger = Logger('mcp_server.http_transport');

/// Configuration for HTTP server transport
@immutable
class HttpServerConfig {
  /// The endpoint path for StreamableHTTP requests
  final String endpoint;
  
  /// The host to bind to
  final String host;
  
  /// The port to listen on
  final int port;
  
  /// Fallback ports to try if the primary port is unavailable
  final List<int> fallbackPorts;
  
  /// CORS configuration
  final CorsConfig corsConfig;
  
  /// Compression configuration
  final CompressionConfig? compressionConfig;
  
  /// Authentication token (optional)
  final String? authToken;
  
  /// Maximum request body size in bytes
  final int maxRequestSize;
  
  /// Request timeout
  final Duration requestTimeout;
  
  const HttpServerConfig({
    this.endpoint = '/mcp',
    this.host = 'localhost',
    this.port = 8080,
    this.fallbackPorts = const [8081, 8082, 8083],
    this.corsConfig = const CorsConfig(),
    this.compressionConfig,
    this.authToken,
    this.maxRequestSize = 10 * 1024 * 1024, // 10MB
    this.requestTimeout = const Duration(seconds: 30),
  });
}

/// CORS configuration
@immutable
class CorsConfig {
  final String allowOrigin;
  final String allowMethods;
  final String allowHeaders;
  final int maxAge;
  
  const CorsConfig({
    this.allowOrigin = '*',
    this.allowMethods = 'POST, OPTIONS',
    this.allowHeaders = 'Content-Type, Authorization',
    this.maxAge = 86400,
  });
}

/// HTTP Server Transport implementation
class HttpServerTransport implements ServerTransport {
  final HttpServerConfig config;
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  
  HttpServer? _server;
  bool _isClosed = false;
  final Map<dynamic, HttpRequest> _pendingRequests = {};
  
  HttpServerTransport({required this.config}) {
    // Start the server when transport is created
    _initialize();
  }
  
  void _initialize() {
    // Start server asynchronously
    start();
  }
  
  /// Start the HTTP server
  Future<void> start() async {
    try {
      _server = await _startServer(config.port);
      _logger.debug('HTTP server listening on port ${config.port}');
    } catch (e) {
      _logger.debug('Failed to start server on port ${config.port}: $e');
      
      // Try fallback ports
      for (final fallbackPort in config.fallbackPorts) {
        try {
          _server = await _startServer(fallbackPort);
          _logger.debug('HTTP server listening on fallback port $fallbackPort');
          break;
        } catch (e) {
          _logger.debug('Failed to start server on fallback port $fallbackPort: $e');
        }
      }
      
      if (_server == null) {
        _closeCompleter.completeError('Failed to start server on any port');
        throw Exception('Failed to start HTTP server on any available port');
      }
    }
  }
  
  Future<HttpServer> _startServer(int port) async {
    // Parse host and bind accordingly
    final address = config.host == 'localhost' || config.host == '127.0.0.1' 
        ? InternetAddress.loopbackIPv4
        : config.host == '::1'
        ? InternetAddress.loopbackIPv6
        : config.host == '0.0.0.0'
        ? InternetAddress.anyIPv4
        : config.host == '::'
        ? InternetAddress.anyIPv6
        : InternetAddress.tryParse(config.host) ?? InternetAddress.loopbackIPv4;
    
    final server = await HttpServer.bind(address, port);
    
    server.listen((HttpRequest request) {
      // Only handle the configured endpoint for StreamableHTTP
      if (request.uri.path == config.endpoint) {
        _handleRequest(request);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.close();
      }
    });
    
    return server;
  }
  
  void _handleRequest(HttpRequest request) async {
    try {
      // Set CORS headers
      _setCorsHeaders(request.response);
      
      // Handle OPTIONS request
      if (request.method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        return;
      }
      
      // Only allow POST requests
      if (request.method != 'POST') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }
      
      // Check authentication if required
      if (config.authToken != null) {
        final authHeader = request.headers.value('Authorization');
        if (authHeader != 'Bearer ${config.authToken}') {
          request.response.statusCode = HttpStatus.unauthorized;
          request.response.headers.set('Content-Type', 'application/json');
          request.response.write(jsonEncode({'error': 'Unauthorized'}));
          await request.response.close();
          return;
        }
      }
      
      // Check content length
      final contentLength = request.contentLength;
      if (contentLength > config.maxRequestSize) {
        request.response.statusCode = HttpStatus.requestEntityTooLarge;
        await request.response.close();
        return;
      }
      
      // Read request body with timeout
      final body = await utf8.decoder
          .bind(request)
          .join()
          .timeout(config.requestTimeout);
      
      // Parse JSON-RPC request
      dynamic jsonRpcRequest;
      try {
        jsonRpcRequest = jsonDecode(body);
      } catch (e) {
        _sendErrorResponse(
          request.response,
          null,
          -32700,
          'Parse error',
          'Invalid JSON: $e',
        );
        return;
      }
      
      // Validate JSON-RPC format
      if (!_isValidJsonRpc(jsonRpcRequest)) {
        _sendErrorResponse(
          request.response,
          null,
          -32600,
          'Invalid Request',
          'Not a valid JSON-RPC 2.0 request',
        );
        return;
      }
      
      // Handle request vs notification
      if (jsonRpcRequest is Map && jsonRpcRequest.containsKey('id')) {
        // This is a request - store for response matching
        final requestId = jsonRpcRequest['id'];
        _pendingRequests[requestId] = request;
        _logger.debug('Stored request ID: $requestId, method: ${jsonRpcRequest['method']}');
        
        // Forward to message controller
        if (!_messageController.isClosed) {
          _messageController.add(jsonRpcRequest);
        }
        
        // Don't close the request immediately - wait for response in send() method
      } else {
        // This is a notification - handle immediately
        if (!_messageController.isClosed) {
          _messageController.add(jsonRpcRequest);
        }
        
        // Send 202 Accepted for notifications (no response body needed)
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
      }
      
    } catch (e) {
      _logger.debug('Error handling HTTP request: $e');
      if (!request.response.headers.chunkedTransferEncoding) {
        _sendErrorResponse(
          request.response,
          null,
          -32603,
          'Internal error',
          e.toString(),
        );
      }
    }
  }
  
  void _setCorsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', config.corsConfig.allowOrigin);
    response.headers.set('Access-Control-Allow-Methods', config.corsConfig.allowMethods);
    response.headers.set('Access-Control-Allow-Headers', config.corsConfig.allowHeaders);
    response.headers.set('Access-Control-Max-Age', config.corsConfig.maxAge.toString());
  }
  
  bool _isValidJsonRpc(dynamic request) {
    if (request is Map<String, dynamic>) {
      return request['jsonrpc'] == '2.0' && 
             request.containsKey('method') &&
             request['method'] is String;
    } else if (request is List) {
      return request.isNotEmpty && 
             request.every((item) => _isValidJsonRpc(item));
    }
    return false;
  }
  
  void _sendErrorResponse(
    HttpResponse response,
    dynamic id,
    int code,
    String message,
    String? data,
  ) async {
    response.statusCode = HttpStatus.ok; // JSON-RPC errors use 200 OK
    response.headers.set('Content-Type', 'application/json');
    
    final errorResponse = {
      'jsonrpc': '2.0',
      'error': {
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      },
      if (id != null) 'id': id,
    };
    
    response.write(jsonEncode(errorResponse));
    await response.close();
  }
  
  @override
  Stream<dynamic> get onMessage => _messageController.stream;
  
  @override
  Future<void> get onClose => _closeCompleter.future;
  
  @override
  void send(dynamic message) {
    try {
      _logger.debug('HTTP send() called with message: $message');
      
      // Match response to pending request by ID
      if (message is Map && message.containsKey('id')) {
        final requestId = message['id'];
        final request = _pendingRequests.remove(requestId);
        
        _logger.debug('Looking for pending request with ID: $requestId');
        _logger.debug('Current pending requests: ${_pendingRequests.keys.toList()}');
        
        if (request != null) {
          // Send JSON-RPC response
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.set('Content-Type', 'application/json');
          request.response.write(jsonEncode(message));
          request.response.close();
          _logger.debug('HTTP response sent for request ID: $requestId');
        } else {
          _logger.debug('No pending request found for response ID: $requestId');
        }
      } else {
        _logger.debug('Received message without ID, cannot match to HTTP request: $message');
      }
    } catch (e) {
      _logger.debug('Error sending HTTP response: $e');
    }
  }
  
  @override
  void close() async {
    if (_isClosed) return;
    _isClosed = true;
    
    _logger.debug('Closing HTTP server transport');
    
    await _server?.close(force: true);
    
    if (!_messageController.isClosed) {
      _messageController.close();
    }
    
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }
  }
  
  /// Get the actual port the server is listening on
  int? get actualPort => _server?.port;
}

