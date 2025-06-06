/// MCP 2025-03-26 StreamableHTTP Server Transport Implementation
/// Fully compliant with MCP standard specification
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
  
  /// Response mode for JSON: 'sync' or 'async'
  /// - sync: Direct 200 OK response with JSON body
  /// - async: 202 Accepted with polling mechanism
  final String jsonResponseMode;
  
  const StreamableHttpServerConfig({
    this.endpoint = '/mcp',
    this.host = 'localhost',
    this.port = 8080,
    this.fallbackPorts = const [8081, 8082, 8083],
    this.corsConfig = const CorsConfig(),
    this.maxRequestSize = 4 * 1024 * 1024, // 4MB
    this.requestTimeout = const Duration(seconds: 30),
    this.isJsonResponseEnabled = false, // StreamableHTTP uses SSE by default
    this.jsonResponseMode = 'sync', // Default to synchronous JSON responses
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
/// Supports both JSON responses and SSE streaming according to MCP standard
class StreamableHttpServerTransport implements ServerTransport {
  final StreamableHttpServerConfig config;
  final _messageController = StreamController<dynamic>();
  final _closeCompleter = Completer<void>();
  
  HttpServer? _server;
  bool _isClosed = false;
  
  // Session management
  String _sessionId;
  bool _terminated = false;
  
  /// Get the session ID for this transport
  String get sessionId => _sessionId;
  
  // Initialize flag to track first message
  bool _isFirstMessage = true;
  
  // Request tracking for JSON responses
  final Map<dynamic, _PendingRequest> _pendingRequests = {};
  
  // Completers for synchronous JSON mode
  final Map<dynamic, Completer<Map<String, dynamic>>> _pendingCompleters = {};
  
  // Response store for asynchronous JSON mode
  final Map<String, Map<String, dynamic>> _responseStore = {};
  final Map<String, DateTime> _responseTimestamps = {};
  
  // SSE streams per request ID for streaming responses
  final Map<dynamic, SseStreamInfo> _sseStreams = {};
  
  // Message router for proper request/response matching
  final Map<dynamic, StreamController<dynamic>> _messageRouters = {};
  
  // GET stream for server-initiated messages (standalone SSE stream)
  SseStreamInfo? _getStream;
  
  // Queue for responses waiting for GET stream in JSON mode
  final List<EventMessage> _pendingResponseQueue = [];
  
  // Event ID counter for resumability
  int _eventIdCounter = 0;
  
  // Event store for resumability (simplified implementation)
  final Map<String, EventMessage> _eventStore = {};
  
  // Timer for cleanup of old responses
  Timer? _cleanupTimer;
  
  StreamableHttpServerTransport({
    required this.config,
    String? sessionId,
  }) : _sessionId = sessionId ?? _generateSessionId() {
    // Start cleanup timer for async mode
    if (config.isJsonResponseEnabled && config.jsonResponseMode == 'async') {
      _cleanupTimer = Timer.periodic(Duration(minutes: 1), (_) => _cleanupOldResponses());
    }
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
      
      // Normalize paths to handle trailing slashes
      final requestPath = request.uri.path.endsWith('/') && request.uri.path.length > 1
          ? request.uri.path.substring(0, request.uri.path.length - 1)
          : request.uri.path;
      final configEndpoint = config.endpoint.endsWith('/') && config.endpoint.length > 1
          ? config.endpoint.substring(0, config.endpoint.length - 1)
          : config.endpoint;
      
      // Check if this is a response polling request (async mode)
      if (config.isJsonResponseEnabled && 
          config.jsonResponseMode == 'async' &&
          requestPath.startsWith('$configEndpoint/responses/')) {
        await _handleResponsePolling(request);
        return;
      }
      
      if (requestPath != configEndpoint) {
        _sendErrorResponse(
          request.response,
          'Not Found',
          HttpStatus.notFound,
        );
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
    } catch (e, stackTrace) {
      _logger.error('Error handling HTTP request: $e');
      _logger.debug('Stack trace: $stackTrace');
      try {
        _sendErrorResponse(
          request.response,
          'Internal Server Error: ${e.toString()}',
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
    request.response.headers.set('Content-Type', contentTypeJson);
    request.response.headers.set('Content-Length', '0');
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
      
      // Return 202 Accepted for all notifications
      request.response.statusCode = HttpStatus.accepted;
      request.response.headers.set('Content-Type', contentTypeJson);
      request.response.headers.set('Content-Length', '0');
      request.response.headers.set(mcpSessionIdHeader, _sessionId);
      await request.response.close();
      return;
    }
    
    // Handle request with ID based on mode
    if (config.isJsonResponseEnabled) {
      // JSON mode
      if (config.jsonResponseMode == 'sync') {
        // Synchronous JSON mode: wait for response and return directly
        await _handleSyncJsonResponse(request, jsonRpcRequest);
      } else {
        // Asynchronous JSON mode: return 202 with polling location
        await _handleAsyncJsonResponse(request, jsonRpcRequest);
      }
    } else {
      // SSE streaming mode (default for StreamableHTTP)
      await _handleSseResponse(request, jsonRpcRequest);
    }
  }
  
  /// Handle synchronous JSON response mode
  Future<void> _handleSyncJsonResponse(HttpRequest request, Map<String, dynamic> jsonRpcRequest) async {
    final requestId = jsonRpcRequest['id'];
    
    // Check if this is an initialize request
    final isInitialize = jsonRpcRequest['method'] == 'initialize';
    
    // Create completer for this request
    final completer = Completer<Map<String, dynamic>>();
    _pendingCompleters[requestId] = completer;
    _logger.debug('Created completer for request ID: $requestId (type: ${requestId.runtimeType})');
    
    // Send to message controller
    if (!_messageController.isClosed) {
      _messageController.add(jsonRpcRequest);
    }
    
    try {
      // Wait for response with timeout
      final response = await completer.future.timeout(
        config.requestTimeout,
        onTimeout: () => throw TimeoutException('Request timeout'),
      );
      
      // For initialize requests, mark as initialized
      if (isInitialize && response['result'] != null) {
        _isFirstMessage = false;
        _logger.debug('StreamableHTTP session initialized successfully');
      }
      
      // Send direct JSON response
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set('Content-Type', 'application/json; charset=utf-8');
      request.response.headers.set(mcpSessionIdHeader, _sessionId);
      // Use UTF-8 encoding to handle international characters
      final responseBytes = utf8.encode(json.encode(response));
      request.response.add(responseBytes);
      await request.response.close();
    } catch (e, stackTrace) {
      _logger.error('Error in _handleSyncJsonResponse: $e');
      _logger.debug('Stack trace: $stackTrace');
      
      // Send error response
      final errorResponse = {
        'jsonrpc': '2.0',
        'error': {
          'code': -32603,
          'message': 'Internal error: ${e.toString()}',
        },
        'id': requestId,
      };
      
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.headers.set('Content-Type', 'application/json; charset=utf-8');
      request.response.add(utf8.encode(json.encode(errorResponse)));
      await request.response.close();
    } finally {
      _pendingCompleters.remove(requestId);
    }
  }
  
  /// Handle asynchronous JSON response mode with polling
  Future<void> _handleAsyncJsonResponse(HttpRequest request, Map<String, dynamic> jsonRpcRequest) async {
    final requestId = jsonRpcRequest['id'];
    final responseKey = '$_sessionId:$requestId';
    
    // Store pending request
    _pendingRequests[requestId] = _PendingRequest(
      request: request,
      timestamp: DateTime.now(),
    );
    
    // Send to message controller
    if (!_messageController.isClosed) {
      _messageController.add(jsonRpcRequest);
    }
    
    // Return 202 Accepted with Location header
    request.response.statusCode = HttpStatus.accepted;
    request.response.headers.set('Content-Type', contentTypeJson);
    request.response.headers.set(mcpSessionIdHeader, _sessionId);
    request.response.headers.set('Location', '${config.endpoint}/responses/$responseKey');
    await request.response.close();
  }
  
  /// Handle response polling for async JSON mode
  Future<void> _handleResponsePolling(HttpRequest request) async {
    final path = request.uri.path;
    final basePath = config.endpoint.endsWith('/') 
        ? config.endpoint.substring(0, config.endpoint.length - 1) 
        : config.endpoint;
    
    final responseKey = path.substring('$basePath/responses/'.length);
    
    _setCorsHeaders(request.response);
    
    if (_responseStore.containsKey(responseKey)) {
      final response = _responseStore[responseKey]!;
      
      // Send the stored response
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set('Content-Type', 'application/json; charset=utf-8');
      request.response.headers.set(mcpSessionIdHeader, _sessionId);
      request.response.add(utf8.encode(json.encode(response)));
      await request.response.close();
      
      // Clean up
      _responseStore.remove(responseKey);
      _responseTimestamps.remove(responseKey);
    } else {
      // Response not ready yet
      request.response.statusCode = HttpStatus.noContent;
      request.response.headers.set(mcpSessionIdHeader, _sessionId);
      await request.response.close();
    }
  }
  
  /// Clean up old responses in async mode
  void _cleanupOldResponses() {
    final now = DateTime.now();
    final timeout = Duration(minutes: 5);
    
    final keysToRemove = <String>[];
    _responseTimestamps.forEach((key, timestamp) {
      if (now.difference(timestamp) > timeout) {
        keysToRemove.add(key);
      }
    });
    
    for (final key in keysToRemove) {
      _responseStore.remove(key);
      _responseTimestamps.remove(key);
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
    
    // Create message router for this request
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
    _logger.debug('Handling GET request');
    _logger.debug('Headers: ${request.headers}');
    
    // Validate Accept header - more lenient for GET requests
    final acceptHeader = request.headers.value('accept');
    _logger.debug('Accept header: $acceptHeader');
    
    if (acceptHeader != null && 
        !acceptHeader.contains(contentTypeSse) && 
        !acceptHeader.contains('*/*')) {
      _logger.debug('Rejecting GET request - wrong Accept header');
      _sendErrorResponse(
        request.response,
        'Not Acceptable: Client must accept text/event-stream',
        HttpStatus.notAcceptable,
      );
      return;
    }
    
    if (!await _validateSession(request)) {
      _logger.debug('Session validation failed for GET request');
      return;
    }
    
    _logger.debug('Session validated successfully');
    
    // Check if GET stream already exists
    if (_getStream != null) {
      _logger.debug('GET stream already exists - rejecting');
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
    
    // Send any queued responses (for JSON mode)
    if (config.isJsonResponseEnabled && _pendingResponseQueue.isNotEmpty) {
      _logger.debug('Sending ${_pendingResponseQueue.length} queued responses');
      for (final event in _pendingResponseQueue) {
        _sendSseEvent(_getStream!.controller, event.message, eventId: event.eventId);
      }
      _pendingResponseQueue.clear();
    } else {
      _logger.debug('No queued responses to send. Queue size: ${_pendingResponseQueue.length}');
    }
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
  
  /// Validate Accept headers - MCP spec: POST requires both JSON and SSE
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
  
  /// Validate session
  Future<bool> _validateSession(HttpRequest request) async {
    final sessionId = request.headers.value(mcpSessionIdHeader);
    _logger.debug('Validating session - client ID: $sessionId, server ID: $_sessionId');
    
    // If no session ID is provided, allow it for initial requests
    if (sessionId == null) {
      _logger.debug('No session ID provided - allowing request');
      return true;
    }
    
    // For first message (initialize), adopt the client's session ID
    if (_isFirstMessage) {
      _logger.debug('First message detected - adopting client session ID: $sessionId');
      _sessionId = sessionId;
      return true;
    }
    
    // If session ID is provided, it must match
    if (sessionId != _sessionId) {
      _logger.debug('Session ID mismatch! Client: $sessionId, Server: $_sessionId');
      _sendErrorResponse(
        request.response,
        'Forbidden: Invalid session ID',
        HttpStatus.forbidden,
      );
      return false;
    }
    
    _logger.debug('Session ID matches');
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
    response.headers.set('Content-Type', 'application/json; charset=utf-8');
    response.headers.set(mcpSessionIdHeader, _sessionId);
    
    final error = {
      'error': message,
    };
    
    response.add(utf8.encode(jsonEncode(error)));
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
    response.headers.set('Content-Type', 'application/json; charset=utf-8');
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
    
    response.add(utf8.encode(jsonEncode(errorResponse)));
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
        _logger.debug('Response ID: $requestId (type: ${requestId.runtimeType})');
        
        // Generate event ID for resumability
        final eventId = (_eventIdCounter++).toString();
        
        // Store event for resumability
        _eventStore[eventId] = EventMessage(
          message: Map<String, dynamic>.from(message),
          eventId: eventId,
        );
        
        // Handle based on mode
        if (config.isJsonResponseEnabled) {
          if (config.jsonResponseMode == 'sync') {
            // Synchronous JSON mode: complete the pending completer
            if (_pendingCompleters.containsKey(requestId)) {
              try {
                _logger.debug('Completing completer for request ID: $requestId');
                _pendingCompleters[requestId]!.complete(Map<String, dynamic>.from(message));
                _pendingCompleters.remove(requestId);
                _logger.debug('Successfully completed completer for request ID: $requestId');
              } catch (e, stackTrace) {
                _logger.error('Error completing completer for request ID $requestId: $e');
                _logger.debug('Stack trace: $stackTrace');
              }
            } else {
              _logger.warning('No pending completer for response ID: $requestId');
              _logger.debug('Available completers: ${_pendingCompleters.keys.toList()}');
            }
          } else {
            // Asynchronous JSON mode: store response for polling
            final responseKey = '$_sessionId:$requestId';
            _responseStore[responseKey] = Map<String, dynamic>.from(message);
            _responseTimestamps[responseKey] = DateTime.now();
            _pendingRequests.remove(requestId);
          }
        } else if (_sseStreams.containsKey(requestId)) {
          // SSE response for specific request
          final stream = _sseStreams[requestId]!;
          _sendSseEvent(stream.controller, Map<String, dynamic>.from(message), eventId: eventId);
          
          // If this is a response or error, close the stream
          if (message.containsKey('result') || message.containsKey('error')) {
            stream.controller.close();
            _sseStreams.remove(requestId);
            _messageRouters.remove(requestId)?.close();
          }
        } else {
          // Log when we can't find a pending request for a response
          _logger.warning('No pending request found for response with ID: $requestId');
          _logger.debug('Current pending requests: ${_pendingRequests.keys.toList()}');
          _logger.debug('Current SSE streams: ${_sseStreams.keys.toList()}');
        }
      } else {
        // Notification or server-initiated message
        // Send to GET stream if available
        if (_getStream != null) {
          final eventId = (_eventIdCounter++).toString();
          _eventStore[eventId] = EventMessage(
            message: Map<String, dynamic>.from(message),
            eventId: eventId,
          );
          _sendSseEvent(_getStream!.controller, Map<String, dynamic>.from(message), eventId: eventId);
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
    
    // Cancel cleanup timer
    _cleanupTimer?.cancel();
    
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
    
    // Complete any pending completers with error
    for (final completer in _pendingCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError('Server shutting down');
      }
    }
    _pendingCompleters.clear();
    
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