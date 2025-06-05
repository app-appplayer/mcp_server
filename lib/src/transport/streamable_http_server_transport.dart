/// MCP 2025-03-26 StreamableHTTP Server Transport Implementation
/// Fully compliant with Python MCP SDK specification
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../../logger.dart';
import 'transport.dart';

final Logger _logger = Logger('mcp_server.streamable_http_server_transport');

// MCP StreamableHTTP Headers
const String mcpSessionIdHeader = 'mcp-session-id';
const String lastEventIdHeader = 'last-event-id';

// Content Types
const String contentTypeJson = 'application/json';
const String contentTypeSse = 'text/event-stream';

// Special key for standalone GET stream
const String getStreamKey = '_GET_stream';

/// Configuration for StreamableHTTP server transport
@immutable
class StreamableHttpServerConfig {
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
  
  /// Maximum request body size in bytes
  final int maxRequestSize;
  
  /// Request timeout
  final Duration requestTimeout;
  
  /// Enable JSON response mode instead of SSE (default: false for streaming)
  final bool isJsonResponseEnabled;
  
  const StreamableHttpServerConfig({
    this.endpoint = '/mcp',
    this.host = 'localhost',
    this.port = 8080,
    this.fallbackPorts = const [8081, 8082, 8083],
    this.corsConfig = const CorsConfig(),
    this.maxRequestSize = 4 * 1024 * 1024, // 4MB
    this.requestTimeout = const Duration(seconds: 30),
    this.isJsonResponseEnabled = false, // StreamableHTTP uses SSE by default
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
    this.allowMethods = 'POST, OPTIONS, GET, DELETE',
    this.allowHeaders = 'Content-Type, Authorization, Accept, X-Session-ID, mcp-session-id, last-event-id',
    this.maxAge = 86400,
  });
}

/// Event message with optional ID for SSE
class EventMessage {
  final Map<String, dynamic> message;
  final String? eventId;
  
  EventMessage({required this.message, this.eventId});
}

/// SSE stream information for request-specific streams
class SseStreamInfo {
  final StreamController<String> controller;
  final HttpResponse response;
  final DateTime createdAt;
  
  SseStreamInfo({
    required this.controller, 
    required this.response,
  }) : createdAt = DateTime.now();
}

/// MCP 2025-03-26 StreamableHTTP Server Transport Implementation
/// Supports both JSON responses and SSE streaming according to Python MCP SDK
class StreamableHttpServerTransport implements ServerTransport {
  final StreamableHttpServerConfig config;
  final _messageController = StreamController<dynamic>();
  final _closeCompleter = Completer<void>();
  
  HttpServer? _server;
  bool _isClosed = false;
  
  // Session management
  final String _sessionId;
  bool _terminated = false;
  
  // Request tracking for JSON responses
  final Map<dynamic, _PendingRequest> _pendingRequests = {};
  
  // SSE streams per request ID for streaming responses
  final Map<dynamic, SseStreamInfo> _sseStreams = {};
  
  // Message router for proper request/response matching like Python SDK
  final Map<dynamic, StreamController<dynamic>> _messageRouters = {};
  
  // GET stream for server-initiated messages (standalone SSE stream)
  SseStreamInfo? _getStream;
  
  // Event ID counter for resumability
  int _eventIdCounter = 0;
  
  // Event store for resumability (simplified implementation)
  final Map<String, EventMessage> _eventStore = {};
  
  StreamableHttpServerTransport({
    required this.config,
    String? sessionId,
  }) : _sessionId = sessionId ?? _generateSessionId() {
    // Start server immediately like HTTP transport
    start();
  }
  
  static String _generateSessionId() {
    return const Uuid().v4();
  }
  
  /// Start the HTTP server
  Future<void> start() async {
    _logger.info('Starting StreamableHTTP server...');
    try {
      _logger.info('Attempting to bind to ${config.host}:${config.port}');
      _server = await _startServer(config.port);
      _logger.info('StreamableHTTP server listening on ${config.host}:${config.port}');
    } catch (e) {
      _logger.error('Failed to start server on port ${config.port}: $e');
      
      // Try fallback ports
      for (final fallbackPort in config.fallbackPorts) {
        try {
          _logger.info('Trying fallback port: $fallbackPort');
          _server = await _startServer(fallbackPort);
          _logger.info('StreamableHTTP server listening on ${config.host}:$fallbackPort');
          break;
        } catch (e) {
          _logger.error('Failed to start server on fallback port $fallbackPort: $e');
        }
      }
      
      if (_server == null) {
        final errorMsg = 'Failed to start StreamableHTTP server on any available port';
        _logger.error(errorMsg);
        _closeCompleter.completeError(errorMsg);
        throw Exception(errorMsg);
      }
    }
  }
  
  Future<HttpServer> _startServer(int port) async {
    final address = _parseAddress(config.host);
    final server = await HttpServer.bind(address, port);
    
    server.listen((HttpRequest request) {
      _handleHttpRequest(request);
    });
    
    return server;
  }
  
  InternetAddress _parseAddress(String host) {
    switch (host) {
      case 'localhost':
      case '127.0.0.1':
        return InternetAddress.loopbackIPv4;
      case '::1':
        return InternetAddress.loopbackIPv6;
      case '0.0.0.0':
        return InternetAddress.anyIPv4;
      case '::':
        return InternetAddress.anyIPv6;
      default:
        return InternetAddress.tryParse(host) ?? InternetAddress.loopbackIPv4;
    }
  }
  
  /// Handle incoming HTTP requests according to MCP StreamableHTTP spec
  Future<void> _handleHttpRequest(HttpRequest request) async {
    try {
      if (_terminated) {
        _sendErrorResponse(
          request.response,
          'Not Found: Session has been terminated',
          HttpStatus.notFound,
        );
        return;
      }
      
      if (request.uri.path != config.endpoint) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      
      _setCorsHeaders(request.response);
      
      switch (request.method) {
        case 'OPTIONS':
          await _handleOptionsRequest(request);
          break;
        case 'POST':
          await _handlePostRequest(request);
          break;
        case 'GET':
          await _handleGetRequest(request);
          break;
        case 'DELETE':
          await _handleDeleteRequest(request);
          break;
        default:
          _sendErrorResponse(
            request.response,
            'Method Not Allowed',
            HttpStatus.methodNotAllowed,
          );
      }
    } catch (e) {
      _logger.error('Error handling HTTP request: $e');
      try {
        _sendErrorResponse(
          request.response,
          'Internal Server Error',
          HttpStatus.internalServerError,
        );
      } catch (_) {
        // Response already sent
      }
    }
  }
  
  /// Handle OPTIONS request for CORS
  Future<void> _handleOptionsRequest(HttpRequest request) async {
    request.response.statusCode = HttpStatus.ok;
    await request.response.close();
  }
  
  /// Handle POST request (main JSON-RPC endpoint)
  Future<void> _handlePostRequest(HttpRequest request) async {
    // Validate headers according to MCP StreamableHTTP specification
    if (!_validateAcceptHeaders(request)) {
      _sendErrorResponse(
        request.response,
        'Not Acceptable: Client must accept both application/json and text/event-stream',
        HttpStatus.notAcceptable,
      );
      return;
    }
    
    if (!_validateContentType(request)) {
      _sendErrorResponse(
        request.response,
        'Unsupported Media Type: Content-Type must be application/json',
        HttpStatus.unsupportedMediaType,
      );
      return;
    }
    
    if (!await _validateSession(request)) {
      return;
    }
    
    // Read and parse request body
    final body = await utf8.decoder
        .bind(request)
        .join()
        .timeout(config.requestTimeout);
    
    if (body.length > config.maxRequestSize) {
      _sendErrorResponse(
        request.response,
        'Request Too Large',
        HttpStatus.requestEntityTooLarge,
      );
      return;
    }
    
    Map<String, dynamic> jsonRpcRequest;
    try {
      jsonRpcRequest = jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      _sendJsonRpcError(
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
      _sendJsonRpcError(
        request.response,
        null,
        -32600,
        'Invalid Request',
        'Not a valid JSON-RPC 2.0 request',
      );
      return;
    }
    
    // Handle notification (no response expected)
    if (jsonRpcRequest['id'] == null) {
      // Send to message controller
      if (!_messageController.isClosed) {
        _messageController.add(jsonRpcRequest);
      }
      
      // Return 204 No Content like Python SDK
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    
    // Handle request with response - choose response mode
    if (config.isJsonResponseEnabled) {
      // JSON response mode (simpler mode)
      await _handleJsonResponse(request, jsonRpcRequest);
    } else {
      // SSE streaming mode (default for StreamableHTTP)
      await _handleSseResponse(request, jsonRpcRequest);
    }
  }
  
  /// Handle request with JSON response
  Future<void> _handleJsonResponse(HttpRequest request, Map<String, dynamic> jsonRpcRequest) async {
    final requestId = jsonRpcRequest['id'];
    
    // Store pending request
    _pendingRequests[requestId] = _PendingRequest(
      request: request,
      timestamp: DateTime.now(),
    );
    
    // Create message router for this request like Python SDK
    final messageRouter = StreamController<dynamic>();
    _messageRouters[requestId] = messageRouter;
    
    // Send to message controller
    if (!_messageController.isClosed) {
      _messageController.add(jsonRpcRequest);
    }
  }
  
  /// Handle request with SSE response (StreamableHTTP default)
  Future<void> _handleSseResponse(HttpRequest request, Map<String, dynamic> jsonRpcRequest) async {
    final requestId = jsonRpcRequest['id'];
    
    // Set SSE headers
    request.response.headers.set('Content-Type', contentTypeSse);
    request.response.headers.set('Cache-Control', 'no-cache, no-transform');
    request.response.headers.set('Connection', 'keep-alive');
    request.response.headers.set(mcpSessionIdHeader, _sessionId);
    
    // Create SSE stream for this request
    final sseController = StreamController<String>();
    _sseStreams[requestId] = SseStreamInfo(
      controller: sseController,
      response: request.response,
    );
    
    // Create message router for this request like Python SDK
    final messageRouter = StreamController<dynamic>();
    _messageRouters[requestId] = messageRouter;
    
    // Start sending SSE events with proper UTF-8 encoding
    sseController.stream.listen(
      (data) {
        request.response.add(utf8.encode(data));
      },
      onDone: () async {
        await request.response.close();
        _sseStreams.remove(requestId);
        _messageRouters.remove(requestId)?.close();
      },
      onError: (error) {
        _logger.error('SSE stream error: $error');
        _sseStreams.remove(requestId);
        _messageRouters.remove(requestId)?.close();
      },
    );
    
    // Send to message controller
    if (!_messageController.isClosed) {
      _messageController.add(jsonRpcRequest);
    }
  }
  
  /// Handle GET request (standalone SSE stream for server-initiated messages)
  Future<void> _handleGetRequest(HttpRequest request) async {
    // Validate Accept header - more lenient for GET requests
    final acceptHeader = request.headers.value('accept');
    if (acceptHeader != null && 
        !acceptHeader.contains(contentTypeSse) && 
        !acceptHeader.contains('*/*')) {
      _sendErrorResponse(
        request.response,
        'Not Acceptable: Client must accept text/event-stream',
        HttpStatus.notAcceptable,
      );
      return;
    }
    
    if (!await _validateSession(request)) {
      return;
    }
    
    // Check if GET stream already exists
    if (_getStream != null) {
      _sendErrorResponse(
        request.response,
        'Conflict: Only one SSE stream is allowed per session',
        HttpStatus.conflict,
      );
      return;
    }
    
    // Handle resumability
    final lastEventId = request.headers.value(lastEventIdHeader);
    if (lastEventId != null) {
      await _replayEvents(request, lastEventId);
      return;
    }
    
    // Set SSE headers
    request.response.headers.set('Content-Type', contentTypeSse);
    request.response.headers.set('Cache-Control', 'no-cache, no-transform');
    request.response.headers.set('Connection', 'keep-alive');
    request.response.headers.set(mcpSessionIdHeader, _sessionId);
    
    // Create GET stream
    final sseController = StreamController<String>();
    _getStream = SseStreamInfo(
      controller: sseController,
      response: request.response,
    );
    
    // Start sending SSE events with proper UTF-8 encoding
    sseController.stream.listen(
      (data) {
        request.response.add(utf8.encode(data));
      },
      onDone: () async {
        await request.response.close();
        _getStream = null;
      },
      onError: (error) {
        _logger.error('GET SSE stream error: $error');
        _getStream = null;
      },
    );
  }
  
  /// Handle DELETE request (terminate session)
  Future<void> _handleDeleteRequest(HttpRequest request) async {
    if (!await _validateSession(request)) {
      return;
    }
    
    _terminated = true;
    
    // Close all SSE streams
    for (final stream in _sseStreams.values) {
      await stream.controller.close();
    }
    _sseStreams.clear();
    
    if (_getStream != null) {
      await _getStream!.controller.close();
      _getStream = null;
    }
    
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }
  
  /// Validate Accept headers - Python SDK behavior: POST requires both JSON and SSE
  bool _validateAcceptHeaders(HttpRequest request) {
    final acceptHeader = request.headers.value('accept') ?? '';
    
    // Handle empty or wildcard accept headers
    if (acceptHeader.isEmpty || acceptHeader == '*/*') {
      return true;
    }
    
    final acceptTypes = acceptHeader.split(',').map((s) => s.trim()).toList();
    
    // For POST requests, client must accept both JSON and SSE
    bool hasJson = acceptTypes.any((type) => 
        type.startsWith(contentTypeJson) || type == '*/*');
    bool hasSse = acceptTypes.any((type) => 
        type.startsWith(contentTypeSse) || type == '*/*');
        
    return hasJson && hasSse;
  }
  
  /// Validate Content-Type
  bool _validateContentType(HttpRequest request) {
    final contentType = request.headers.value('content-type') ?? '';
    return contentType.startsWith(contentTypeJson);
  }
  
  /// Validate session - Python SDK behavior
  Future<bool> _validateSession(HttpRequest request) async {
    final sessionId = request.headers.value(mcpSessionIdHeader);
    
    // If no session ID is provided, allow it for initial requests
    if (sessionId == null) {
      return true;
    }
    
    // If session ID is provided, it must match
    if (sessionId != _sessionId) {
      _sendErrorResponse(
        request.response,
        'Forbidden: Invalid session ID',
        HttpStatus.forbidden,
      );
      return false;
    }
    
    return true;
  }
  
  /// Replay events after a given event ID (simplified implementation)
  Future<void> _replayEvents(HttpRequest request, String lastEventId) async {
    // For now, return a simple error - full implementation would replay stored events
    _sendErrorResponse(
      request.response,
      'Bad Request: Event resumption not fully implemented',
      HttpStatus.badRequest,
    );
  }
  
  /// Check if request is valid JSON-RPC
  bool _isValidJsonRpc(Map<String, dynamic> request) {
    return request['jsonrpc'] == '2.0' && 
           request.containsKey('method') &&
           request['method'] is String;
  }
  
  /// Set CORS headers
  void _setCorsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', config.corsConfig.allowOrigin);
    response.headers.set('Access-Control-Allow-Methods', config.corsConfig.allowMethods);
    response.headers.set('Access-Control-Allow-Headers', config.corsConfig.allowHeaders);
    response.headers.set('Access-Control-Max-Age', config.corsConfig.maxAge.toString());
  }
  
  /// Send error response
  void _sendErrorResponse(HttpResponse response, String message, int statusCode) {
    response.statusCode = statusCode;
    response.headers.set('Content-Type', contentTypeJson);
    response.headers.set(mcpSessionIdHeader, _sessionId);
    
    final error = {
      'error': message,
    };
    
    response.write(jsonEncode(error));
    response.close();
  }
  
  /// Send JSON-RPC error
  void _sendJsonRpcError(
    HttpResponse response,
    dynamic id,
    int code,
    String message,
    String? data,
  ) {
    response.statusCode = HttpStatus.ok;
    response.headers.set('Content-Type', contentTypeJson);
    response.headers.set(mcpSessionIdHeader, _sessionId);
    
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
    response.close();
  }
  
  /// Send SSE event
  void _sendSseEvent(StreamController<String> controller, Map<String, dynamic> data, {String? eventId}) {
    final buffer = StringBuffer();
    
    if (eventId != null) {
      buffer.writeln('id: $eventId');
    }
    
    buffer.writeln('event: message');
    buffer.writeln('data: ${jsonEncode(data)}');
    buffer.writeln(); // Empty line to end event
    
    controller.add(buffer.toString());
  }
  
  @override
  Stream<dynamic> get onMessage => _messageController.stream;
  
  @override
  Future<void> get onClose => _closeCompleter.future;
  
  @override
  void send(dynamic message) {
    if (_isClosed) return;
    
    try {
      _logger.debug('StreamableHTTP send() called with message: $message');
      
      if (message is Map && message.containsKey('id')) {
        final requestId = message['id'];
        
        // Generate event ID for resumability
        final eventId = (_eventIdCounter++).toString();
        
        // Store event for resumability
        _eventStore[eventId] = EventMessage(
          message: message as Map<String, dynamic>,
          eventId: eventId,
        );
        
        // Check if this is a response to a specific request
        if (_pendingRequests.containsKey(requestId)) {
          // JSON response mode
          final pendingRequest = _pendingRequests.remove(requestId)!;
          
          pendingRequest.request.response.statusCode = HttpStatus.ok;
          pendingRequest.request.response.headers.set('Content-Type', contentTypeJson);
          pendingRequest.request.response.headers.set(mcpSessionIdHeader, _sessionId);
          
          pendingRequest.request.response.write(jsonEncode(message));
          pendingRequest.request.response.close();
          
          // Clean up message router
          _messageRouters.remove(requestId)?.close();
          
        } else if (_sseStreams.containsKey(requestId)) {
          // SSE response for specific request
          final stream = _sseStreams[requestId]!;
          _sendSseEvent(stream.controller, message, eventId: eventId);
          
          // If this is a response or error, close the stream
          if (message.containsKey('result') || message.containsKey('error')) {
            stream.controller.close();
            _sseStreams.remove(requestId);
            _messageRouters.remove(requestId)?.close();
          }
        }
      } else {
        // Notification or server-initiated message
        // Send to GET stream if available
        if (_getStream != null) {
          final eventId = (_eventIdCounter++).toString();
          _eventStore[eventId] = EventMessage(
            message: message as Map<String, dynamic>,
            eventId: eventId,
          );
          _sendSseEvent(_getStream!.controller, message, eventId: eventId);
        }
      }
    } catch (e, stackTrace) {
      _logger.error('Error sending message: $e');
      _logger.debug('Stack trace: $stackTrace');
    }
  }
  
  @override
  void close() async {
    if (_isClosed) return;
    _isClosed = true;
    
    _logger.info('Closing StreamableHTTP server transport');
    
    // Close all SSE streams
    for (final stream in _sseStreams.values) {
      await stream.controller.close();
    }
    _sseStreams.clear();
    
    if (_getStream != null) {
      await _getStream!.controller.close();
      _getStream = null;
    }
    
    // Close pending requests and message routers
    for (final pendingRequest in _pendingRequests.values) {
      try {
        pendingRequest.request.response.statusCode = HttpStatus.serviceUnavailable;
        await pendingRequest.request.response.close();
      } catch (e) {
        _logger.debug('Error closing pending request: $e');
      }
    }
    _pendingRequests.clear();
    
    // Close message routers
    for (final router in _messageRouters.values) {
      await router.close();
    }
    _messageRouters.clear();
    
    // Close server
    await _server?.close(force: true);
    
    // Close message controller
    if (!_messageController.isClosed) {
      await _messageController.close();
    }
    
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }
  }
}

/// Pending request information
class _PendingRequest {
  final HttpRequest request;
  final DateTime timestamp;
  
  _PendingRequest({
    required this.request,
    required this.timestamp,
  });
}