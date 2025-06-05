import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../logger.dart';
import '../models/models.dart';
import '../transport/transport.dart';
import '../protocol/protocol.dart';
import '../protocol/capabilities.dart';
import '../middleware/rate_limiter.dart';
import '../metrics/metrics_collector.dart';
import '../auth/auth_middleware.dart';

final Logger _logger = Logger('mcp_server.server');

/// Callback type for tool execution progress updates
typedef ProgressCallback = void Function(double progress, String message);

/// Callback type for checking if operation is cancelled
typedef IsCancelledCheck = bool Function();

/// Type definition for tool handler functions with cancellation and progress reporting
typedef ToolHandler = Future<dynamic> Function(Map<String, dynamic> arguments);

/// Type definition for resource handler functions
typedef ResourceHandler = Future<dynamic> Function(String uri, Map<String, dynamic> params);

/// Type definition for prompt handler functions
typedef PromptHandler = Future<dynamic> Function(Map<String, dynamic> arguments);

/// Main MCP Server class that handles all server-side protocol operations
class Server implements ServerInterface {
  /// Name of the MCP server
  @override
  final String name;

  /// Version of the MCP server implementation
  @override
  final String version;

  /// Server capabilities configuration
  @override
  final ServerCapabilities capabilities;

  /// Protocol versions this server implements
  final List<String> supportedProtocolVersions = McpProtocol.supportedVersions;

  /// Map of registered tools by name
  final Map<String, Tool> _tools = {};

  /// Map of tool handlers by name
  final Map<String, ToolHandler> _toolHandlers = {};

  /// Map of registered resources by URI
  final Map<String, Resource> _resources = {};

  /// Map of resource handlers by URI
  final Map<String, ResourceHandler> _resourceHandlers = {};

  /// Map of registered prompts by name
  final Map<String, Prompt> _prompts = {};

  /// Map of prompt handlers by name
  final Map<String, PromptHandler> _promptHandlers = {};
  
  /// Map of resource templates
  final Map<String, ResourceTemplate> _resourceTemplates = {};

  /// Transport connection
  ServerTransport? _transport;

  /// Session management
  final Map<String, ClientSession> _sessions = {};

  /// Resource subscription system (URI -> Set of Session IDs)
  final Map<String, Set<String>> _resourceSubscriptions = {};

  /// Cache for resource content
  final Map<String, CachedResource> _resourceCache = {};

  /// Default cache duration
  final Duration defaultCacheMaxAge = Duration(minutes: 5);

  /// Pending operations for cancellation support
  final Map<String, PendingOperation> _pendingOperations = {};

  // Pending sampling requests tracker
  final Map<String, Completer<Map<String, dynamic>>> _pendingSamplingRequests = {};
  
  // Batch request tracking
  final Map<String, BatchRequestTracker> _batchRequests = {};

  /// Server start time for health metrics
  final DateTime _startTime = DateTime.now();

  /// Metrics for performance monitoring
  final Map<String, int> _metricCounters = {};
  final Map<String, Stopwatch> _metricTimers = {};

  /// Stream controller for handling incoming messages
  final _messageController = StreamController<JsonRpcMessage>.broadcast();

  /// Stream controllers for session events
  final _connectStreamController = StreamController<ClientSession>.broadcast();
  final _disconnectStreamController = StreamController<ClientSession>.broadcast();
  
  /// Stream controllers for change events
  final _toolsChangedController = StreamController<void>.broadcast();
  final _resourcesChangedController = StreamController<void>.broadcast();
  final _promptsChangedController = StreamController<void>.broadcast();
  
  /// Server roots
  final List<Root> _roots = [];
  
  /// Rate limiter
  RateLimiter? _rateLimiter;
  
  /// Authentication middleware
  AuthMiddleware? _authMiddleware;
  
  /// Metrics collector
  late final MetricsCollector _metricsCollector;
  late final StandardMetrics _standardMetrics;

  /// Stream of session connection events
  @override
  Stream<ClientSession> get onConnect => _connectStreamController.stream;

  /// Stream of session disconnection events
  @override
  Stream<ClientSession> get onDisconnect => _disconnectStreamController.stream;
  
  /// Stream of tools change events
  Stream<void> get onToolsChanged => _toolsChangedController.stream;
  
  /// Stream of resources change events
  Stream<void> get onResourcesChanged => _resourcesChangedController.stream;
  
  /// Stream of prompts change events
  Stream<void> get onPromptsChanged => _promptsChangedController.stream;

  /// Whether the server is currently connected
  bool get isConnected => _transport != null;

  /// Creates a new MCP server with the specified parameters
  Server({
    required this.name,
    required this.version,
    this.capabilities = const ServerCapabilities(),
  }) {
    _metricsCollector = MetricsCollector();
    _standardMetrics = StandardMetrics(_metricsCollector);
    
    // Initialize resource counters
    _updateResourceMetrics();
  }

  /// Connect the server to a transport
  void connect(ServerTransport transport) {
    if (_transport != null) {
      _logger.debug('Server already has a transport connected');

      // Handle STDIO transport specifically
      if (transport is StdioServerTransport && _transport is StdioServerTransport) {
        _logger.debug('Attempting to connect another STDIO transport - reusing existing connection');
        // Use existing transport instead of the new one
        transport = _transport as StdioServerTransport;
      } else {
        throw McpError('Server is already connected to a transport');
      }
    }

    _transport = transport;

    // Create a new session
    final sessionId = _createSession(transport);

    try {
      transport.onMessage.listen((rawMessage) {
        _handleMessage(sessionId, rawMessage);
      }, onError: (error) {
        _logger.error('Error from transport message stream: $error');
      });

      transport.onClose.then((_) {
        _removeSession(sessionId);
        _onDisconnect();
      }).catchError((error) {
        _logger.error('Transport close error: $error');
        _removeSession(sessionId);
        _onDisconnect();
      });
    } catch (e) {
      _logger.error('Failed to setup transport listeners: $e');
    }

    // Set up message processing with better error handling
    _messageController.stream.listen((message) async {
      try {
        await _processMessage(message.sessionId, message);
      } catch (e, stackTrace) {
        _logger.error('Error processing message: $e');
        _logger.debug('Stack trace: $stackTrace');

        try {
          _sendErrorResponse(message.sessionId, message.id, ErrorCode.internalError, 'Internal error: $e');
        } catch (sendError) {
          _logger.error('Failed to send error response: $sendError');
        }
      }
    }, onError: (error) {
      _logger.error('Error in message stream: $error');
    });
  }

  /// Create a new client session
  String _createSession(ServerTransport transport) {
    final sessionId = Uuid().v4();

    final session = ClientSession(
      id: sessionId,
      connectedAt: DateTime.now(),
      transport: transport,
    );
    session.capabilities = {};

    _sessions[sessionId] = session;
    _logger.debug('Created session: $sessionId');

    // Update metrics
    _metricsCollector.gauge('mcp_connections_active').set(_sessions.length.toDouble());
    _metricsCollector.counter('mcp_connections_total').increment();

    // Emit connection event
    _connectStreamController.add(session);

    return sessionId;
  }

  /// Remove a client session
  void _removeSession(String sessionId) {
    final session = _sessions[sessionId];
    if (session != null) {
      // Only emit event if the stream controller is not closed
      if (!_disconnectStreamController.isClosed) {
        _disconnectStreamController.add(session);
      }
    }

    _sessions.remove(sessionId);
    _logger.debug('Removed session: $sessionId');
    
    // Update metrics
    _metricsCollector.gauge('mcp_connections_active').set(_sessions.length.toDouble());

    // Remove session from resource subscriptions
    for (final uri in _resourceSubscriptions.keys) {
      _resourceSubscriptions[uri]?.remove(sessionId);
    }

    // Clean up empty subscription entries
    _resourceSubscriptions.removeWhere((_, subscribers) => subscribers.isEmpty);

    // Cancel any pending operations for this session
    _pendingOperations.values
        .where((op) => op.sessionId == sessionId)
        .forEach((op) => op.isCancelled = true);

    // Remove completed or cancelled operations
    _pendingOperations.removeWhere((_, op) => op.isCancelled);
  }

  /// Register a pending operation for cancellation support
  PendingOperation registerOperation(String sessionId, String type) {
    final operationId = Uuid().v4();

    final operation = PendingOperation(
      id: operationId,
      sessionId: sessionId,
      type: type,
    );

    _pendingOperations[operationId] = operation;
    incrementMetric('operations.registered');

    return operation;
  }

  /// Send progress notification for a tool operation
  void notifyProgress(String operationId, double progress, String message) {
    // Find the session and request ID for this operation
    final operation = _pendingOperations[operationId];
    if (operation?.requestId != null) {
      sendProgressNotification(
          operation!.sessionId,
          operation.requestId!,
          progress
      );
    }
  }

  /// Check if operation is cancelled
  bool isOperationCancelled(String operationId) {
    final operation = _pendingOperations[operationId];
    return operation?.isCancelled ?? false;
  }

  /// Register a tool call and get an operation ID for progress/cancellation
  String registerToolCall(String toolName, String sessionId, dynamic requestId) {
    final operationId = Uuid().v4();
    _pendingOperations[operationId] = PendingOperation(
        id: operationId,
        sessionId: sessionId,
        type: 'tool:$toolName',
        requestId: requestId.toString()
    );
    return operationId;
  }

  /// Add a tool to the server
  @override
  void addTool({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required ToolHandler handler,
  }) {
    _logger.debug('Adding tool: $name');

    if (_tools.containsKey(name)) {
      _logger.debug('Tool with name "$name" already exists');
      throw McpError('Tool with name "$name" already exists');
    }

    final tool = Tool(
      name: name,
      description: description,
      inputSchema: inputSchema,
    );

    _tools[name] = tool;
    _toolHandlers[name] = handler;

    _logger.debug('Tool added successfully: $name');
    _logger.debug('Total tools: ${_tools.length}');

    // Notify clients about tool changes if connected and supported
    if (isConnected && capabilities.hasTools && capabilities.toolsListChanged) {
      _broadcastNotification('tools/listChanged', {});
    }
    
    // Emit change event
    _toolsChangedController.add(null);
    
    // Update metrics
    _updateResourceMetrics();
  }

  /// Add a resource to the server
  @override
  void addResource({
    required String uri,
    required String name,
    required String description,
    required String mimeType,
    Map<String, dynamic>? uriTemplate,
    required ResourceHandler handler,
  }) {
    if (_resources.containsKey(uri)) {
      throw McpError('Resource with URI "$uri" already exists');
    }

    final resource = Resource(
      uri: uri,
      name: name,
      description: description,
      mimeType: mimeType,
      uriTemplate: uriTemplate,
    );

    _resources[uri] = resource;
    _resourceHandlers[uri] = handler;

    // Notify clients about resource changes if connected and supported
    if (isConnected && capabilities.hasResources && capabilities.resourcesListChanged) {
      _broadcastNotification('resources/listChanged', {});
    }
    
    // Emit change event
    _resourcesChangedController.add(null);
  }

  /// Add a prompt to the server
  @override
  void addPrompt({
    required String name,
    required String description,
    required List<PromptArgument> arguments,
    required PromptHandler handler,
  }) {
    if (_prompts.containsKey(name)) {
      throw McpError('Prompt with name "$name" already exists');
    }

    final prompt = Prompt(
      name: name,
      description: description,
      arguments: arguments,
    );

    _prompts[name] = prompt;
    _promptHandlers[name] = handler;

    // Notify clients about prompt changes if connected and supported
    if (isConnected && capabilities.hasPrompts && capabilities.promptsListChanged) {
      _broadcastNotification('prompts/listChanged', {});
    }
    
    // Emit change event
    _promptsChangedController.add(null);
  }

  /// Remove a tool from the server
  @override
  void removeTool(String name) {
    if (!_tools.containsKey(name)) {
      throw McpError('Tool with name "$name" does not exist');
    }

    _tools.remove(name);
    _toolHandlers.remove(name);

    // Notify clients about tool changes if connected and supported
    if (isConnected && capabilities.hasTools && capabilities.toolsListChanged) {
      _broadcastNotification('tools/listChanged', {});
    }
    
    // Emit change event
    _toolsChangedController.add(null);
    
    // Update metrics
    _updateResourceMetrics();
  }

  /// Remove a resource from the server
  @override
  void removeResource(String uri) {
    if (!_resources.containsKey(uri)) {
      throw McpError('Resource with URI "$uri" does not exist');
    }

    _resources.remove(uri);
    _resourceHandlers.remove(uri);

    // Invalidate cache for this resource
    _resourceCache.remove(uri);

    // Notify clients about resource changes if connected and supported
    if (isConnected && capabilities.hasResources && capabilities.resourcesListChanged) {
      _broadcastNotification('resources/listChanged', {});
    }
    
    // Emit change event
    _resourcesChangedController.add(null);
  }

  /// Remove a prompt from the server
  @override
  void removePrompt(String name) {
    if (!_prompts.containsKey(name)) {
      throw McpError('Prompt with name "$name" does not exist');
    }

    _prompts.remove(name);
    _promptHandlers.remove(name);

    // Notify clients about prompt changes if connected and supported
    if (isConnected && capabilities.hasPrompts && capabilities.promptsListChanged) {
      _broadcastNotification('prompts/listChanged', {});
    }
    
    // Emit change event
    _promptsChangedController.add(null);
  }

  /// Send a logging notification to the client
  void sendLog(McpLogLevel level, String message, {String? logger, dynamic data}) {
    if (!isConnected) return;

    // Convert level enum to string as per MCP 2025-03-26 specification
    final levelString = switch (level) {
      McpLogLevel.debug => 'debug',
      McpLogLevel.info => 'info',
      McpLogLevel.notice => 'notice',
      McpLogLevel.warning => 'warning',
      McpLogLevel.error => 'error',
      McpLogLevel.critical => 'critical',
      McpLogLevel.alert => 'alert',
      McpLogLevel.emergency => 'emergency',
    };

    final params = <String, dynamic>{
      'level': levelString,
    };

    if (logger != null) {
      params['logger'] = logger;
    }

    // According to MCP 2025-03-26 spec, message goes in data object
    final logData = <String, dynamic>{
      'message': message,
    };
    
    if (data != null) {
      // Merge additional data if provided
      if (data is Map<String, dynamic>) {
        logData.addAll(data);
      } else {
        logData['additional'] = data;
      }
    }
    
    params['data'] = logData;

    // Use correct method name as per MCP 2025-03-26 specification
    _broadcastNotification('notifications/message', params);
  }

  /// Send progress notification to the client
  void sendProgressNotification(String sessionId, String progressToken, double progress, [double? total]) {
    if (!isConnected) return;

    final notification = ProgressNotification(
      progressToken: progressToken,
      progress: progress,
      total: total,
    );

    _sendNotification(sessionId, 'notifications/progress', notification.toJson());
  }

  /// Notify clients about a resource update
  void notifyResourceUpdated(String uri, ResourceContent content) {
    // Invalidate cache
    _resourceCache.remove(uri);

    if (!isConnected || !capabilities.hasResources) return;

    final subscribers = _resourceSubscriptions[uri];
    if (subscribers == null || subscribers.isEmpty) return;

    final notification = {
      'uri': uri,
      'content': content.toJson(),
    };

    for (final sessionId in subscribers) {
      if (_sessions.containsKey(sessionId)) {
        _sendNotification(sessionId, 'notifications/resources/updated', notification);
      }
    }
  }

  /// Store client roots information
  void _storeClientRoots(String sessionId, List<Root> roots) {
    final session = _sessions[sessionId];
    if (session != null) {
      session.roots = roots.map((r) => r.toJson()).toList();
      _logger.debug('Stored ${roots.length} client roots for session $sessionId');
    }
  }

  /// Check if a path is within client roots
  bool isPathWithinRoots(String sessionId, String path) {
    final session = _sessions[sessionId];
    if (session == null) return false;

    if (session.roots.isEmpty) return true; // No roots defined means all paths allowed

    for (final root in session.roots) {
      final rootUri = root['uri'] as String?;
      if (rootUri != null && path.startsWith(rootUri)) {
        return true;
      }
    }

    return false;
  }

  /// Get cached resource if available
  CachedResource? getCachedResource(String uri) {
    final cached = _resourceCache[uri];
    if (cached == null) return null;

    // Remove expired cache entry
    if (cached.isExpired) {
      _resourceCache.remove(uri);
      return null;
    }

    incrementMetric('cache.hits');
    return cached;
  }

  /// Cache a resource
  void cacheResource(String uri, ReadResourceResult content, [Duration? maxAge]) {
    _resourceCache[uri] = CachedResource(
      uri: uri,
      content: content,
      cachedAt: DateTime.now(),
      maxAge: maxAge ?? defaultCacheMaxAge,
    );
    incrementMetric('cache.stores');
  }

  /// Invalidate cache for a resource
  void invalidateCache(String uri) {
    if (_resourceCache.remove(uri) != null) {
      incrementMetric('cache.invalidations');
    }
  }

  /// Get server health information
  @override
  ServerHealth getHealth() {
    final now = DateTime.now();
    final uptime = now.difference(_startTime);

    return ServerHealth(
      isRunning: isConnected,
      connectedSessions: _sessions.length,
      registeredTools: _tools.length,
      registeredResources: _resources.length,
      registeredPrompts: _prompts.length,
      startTime: _startTime,
      uptime: uptime,
      metrics: {
        'counters': Map<String, int>.from(_metricCounters),
        'timers': _metricTimers.map((key, timer) =>
            MapEntry(key, timer.elapsed.inMilliseconds)),
      },
    );
  }

  /// Increment metric counter
  void incrementMetric(String name, [int amount = 1]) {
    _metricCounters[name] = (_metricCounters[name] ?? 0) + amount;
  }

  /// Start timer for a metric
  Stopwatch startTimer(String name) {
    final timer = Stopwatch()..start();
    _metricTimers[name] = timer;
    return timer;
  }

  /// Stop timer for a metric
  void stopTimer(String name) {
    _metricTimers[name]?.stop();
  }

  /// Disconnect the server from its transport
  void disconnect() {
    if (_transport != null) {
      _transport!.close();
      _onDisconnect();
    }
  }

  /// Handle transport disconnection
  void _onDisconnect() {
    _transport = null;
    _logger.debug('Transport disconnected');
  }

  /// Dispose server resources
  void dispose() {
    disconnect();

    // Close stream controllers
    _messageController.close();
    _connectStreamController.close();
    _disconnectStreamController.close();
    _toolsChangedController.close();
    _resourcesChangedController.close();
    _promptsChangedController.close();
  }

  /// Handle incoming messages from the transport
  void _handleMessage(String sessionId, dynamic rawMessage) {
    try {
      final parsed = rawMessage is String ? jsonDecode(rawMessage) : rawMessage;
      
      // Check if it's a batch request (array of requests)
      if (parsed is List) {
        _handleBatchRequest(sessionId, parsed);
      } else if (parsed is Map<String, dynamic>) {
        final message = JsonRpcMessage.fromJson(parsed);
        message.sessionId = sessionId; // Attach session ID
        _messageController.add(message);
      } else {
        _sendErrorResponse(sessionId, null, ErrorCode.invalidRequest, 'Invalid request format');
      }
    } catch (e) {
      _logger.error('Parse error: $e');
      _sendErrorResponse(sessionId, null, ErrorCode.parseError, 'Parse error: $e');
    }
  }
  
  /// Handle batch requests
  Future<void> _handleBatchRequest(String sessionId, List<dynamic> batch) async {
    if (batch.isEmpty) {
      _sendErrorResponse(sessionId, null, ErrorCode.invalidRequest, 'Empty batch request');
      return;
    }
    
    final batchId = Uuid().v4();
    final validRequests = <JsonRpcMessage>[];
    final immediateResponses = <Map<String, dynamic>>[];
    
    // First pass: validate and parse all requests
    for (final item in batch) {
      if (item is! Map<String, dynamic>) {
        immediateResponses.add({
          'jsonrpc': '2.0',
          'error': {
            'code': ErrorCode.invalidRequest,
            'message': 'Invalid request in batch',
          },
          'id': null,
        });
        continue;
      }
      
      try {
        final message = JsonRpcMessage.fromJson(item);
        message.sessionId = sessionId;
        
        // Tag with batch ID for tracking
        if (message.id != null) {
          message.batchId = batchId;
        }
        
        validRequests.add(message);
      } catch (e) {
        final id = item['id'];
        if (id != null) {
          immediateResponses.add({
            'jsonrpc': '2.0',
            'error': {
              'code': ErrorCode.parseError,
              'message': 'Parse error: $e',
            },
            'id': id,
          });
        }
      }
    }
    
    // Calculate expected responses (non-notification requests)
    final expectedResponses = validRequests.where((m) => !m.isNotification).length;
    
    if (expectedResponses > 0) {
      // Create batch tracker
      final tracker = BatchRequestTracker(
        batchId: batchId,
        totalRequests: expectedResponses,
      );
      
      // Add immediate error responses
      for (final response in immediateResponses) {
        if (response['id'] != null) {
          tracker.addResponse(response['id'], response);
        }
      }
      
      _batchRequests[batchId] = tracker;
      
      // Process all valid requests
      for (final message in validRequests) {
        _messageController.add(message);
      }
      
      // Wait for batch completion with timeout
      final timeout = Duration(seconds: 30);
      final startTime = DateTime.now();
      
      while (!tracker.isComplete && 
             DateTime.now().difference(startTime) < timeout) {
        await Future.delayed(Duration(milliseconds: 10));
      }
      
      // Send batch response
      final batchResponse = tracker.getBatchResponse();
      if (batchResponse.isNotEmpty) {
        _sendBatchResponse(sessionId, batchResponse);
      }
      
      // Clean up
      _batchRequests.remove(batchId);
    } else {
      // Only notifications or errors, send immediate response if any
      if (immediateResponses.isNotEmpty) {
        _sendBatchResponse(sessionId, immediateResponses);
      }
    }
    
    _logger.debug('Batch request processed: $batchId with ${batch.length} items');
  }

  /// Process a JSON-RPC message
  Future<void> _processMessage(String sessionId, JsonRpcMessage message) async {
    final timerName = 'message.${message.isRequest ? "request" : "notification"}.${message.method}';
    final requestId = '$sessionId:${message.id ?? 'notif'}:${DateTime.now().microsecondsSinceEpoch}';
    
    startTimer(timerName);
    if (message.method != null) {
      _standardMetrics.startRequestTimer(requestId, message.method!);
      _standardMetrics.trackRequest(message.method!);
    }

    try {
      incrementMetric('messages.total');

      if (message.isNotification) {
        incrementMetric('messages.notifications');
        await _handleNotification(sessionId, message);
      } else if (message.isRequest) {
        incrementMetric('messages.requests');
        await _handleRequest(sessionId, message);
      } else {
        incrementMetric('messages.invalid');
        _sendErrorResponse(sessionId, message.id, ErrorCode.invalidRequest, 'Invalid request', null, message.batchId);
      }

      incrementMetric('messages.success');
      if (message.method != null) {
        _standardMetrics.trackSuccess(message.method!);
      }
    } catch (e, stackTrace) {
      incrementMetric('messages.errors');
      _logger.error('Error processing message: $e');
      _logger.debug('Stacktrace: $stackTrace');
      
      if (message.method != null) {
        _standardMetrics.trackError(message.method!, ErrorCode.internalError);
      }

      _sendErrorResponse(
          sessionId,
          message.id,
          ErrorCode.internalError,
          'Internal server error: ${e.toString()}',
          null,
          message.batchId
      );
    } finally {
      stopTimer(timerName);
      if (message.method != null) {
        _standardMetrics.stopRequestTimer(requestId, message.method!);
      }
    }
  }

  /// Handle a JSON-RPC notification
  Future<void> _handleNotification(String sessionId, JsonRpcMessage notification) async {
    _logger.debug('Received notification: ${notification.method}');

    // Handle client notifications
    switch (notification.method) {
      case 'initialized':
      case 'notifications/initialized':
        _logger.debug('Client initialized notification received');
        final session = _sessions[sessionId];
        if (session != null) {
          session.isInitialized = true;
        }
        sendLog(McpLogLevel.info, 'Client initialized successfully');
        break;

      case 'client/ready':
        _logger.debug('Client ready notification received');
        break;

      case 'notifications/roots/list_changed':
        final rootsData = notification.params?['roots'] as List<dynamic>?;
        if (rootsData != null) {
          final roots = rootsData
              .map((r) => Root(
            uri: r['uri'],
            name: r['name'],
            description: r['description'],
          ))
              .toList();
          _storeClientRoots(sessionId, roots);
        }
        break;

      case 'sampling/response':
        await _handleSamplingResponse(sessionId, notification);
        break;

      default:
        _logger.debug('Unknown notification: ${notification.method}');
        break;
    }
  }

  /// Handle a JSON-RPC request
  Future<void> _handleRequest(String sessionId, JsonRpcMessage request) async {
    _logger.debug('🎯 _handleRequest called - sessionId: $sessionId, method: ${request.method}, id: ${request.id}');
    // Special case for initialize which determines protocol version
    if (request.method == 'initialize') {
      await _handleInitialize(sessionId, request);
      return;
    }

    // Must be initialized to use other methods
    final session = _sessions[sessionId];
    if (session == null || !session.isInitialized) {
      _sendErrorResponse(
          sessionId,
          request.id,
          ErrorCode.invalidRequest,
          'Session not initialized yet. Send initialize request first.',
          null,
          request.batchId
      );
      return;
    }
    
    // Check authentication if middleware is enabled
    if (_authMiddleware != null && McpMethodAuth.requiresAuth(request.method ?? '')) {
      final authResult = await _authenticateRequest(sessionId, request);
      if (authResult != null && !authResult.isAuthenticated) {
        _sendErrorResponse(
          sessionId,
          request.id,
          ErrorCode.unauthorized,
          authResult.error ?? 'Authentication required',
          null,
          request.batchId
        );
        return;
      }
      
      // Store auth context in session
      if (authResult != null && authResult.isAuthenticated) {
        session.authContext = AuthContext(
          userInfo: authResult.userInfo!,
          scopes: authResult.validatedScopes ?? [],
          timestamp: DateTime.now(),
        );
      }
    }
    
    // Check rate limit
    if (_rateLimiter != null) {
      final rateLimitResult = _rateLimiter!.checkLimit(
        sessionId: sessionId,
        method: request.method ?? '',
        params: request.params,
      );
      
      if (!rateLimitResult.allowed) {
        _metricsCollector.counter('mcp_rate_limit_exceeded_total', 
            labels: {'method': request.method!}).increment();
        
        _sendErrorResponse(
          sessionId,
          request.id,
          ErrorCode.rateLimited,
          'Rate limit exceeded. Please retry after ${rateLimitResult.retryAfter?.inSeconds ?? 0} seconds',
          {
            'retryAfter': rateLimitResult.retryAfter?.inSeconds ?? 0,
            'resetTime': rateLimitResult.resetTime.toIso8601String(),
          },
          request.batchId
        );
        return;
      }
    }

    // Route requests based on negotiated protocol version
    final protocolVersion = session.negotiatedProtocolVersion;
    if (protocolVersion == null) {
      _sendErrorResponse(
          sessionId,
          request.id,
          ErrorCode.incompatibleVersion,
          'No protocol version negotiated'
      );
      return;
    }

    switch (request.method) {
    // Common methods across protocol versions
      case 'tools/list':
        await _handleToolsList(sessionId, request);
        break;

      case 'tools/call':
        await _handleToolCall(sessionId, request);
        break;

      case 'resources/list':
        _logger.debug('🔍 Handling resources/list request...');
        await _handleResourcesList(sessionId, request);
        _logger.debug('✅ resources/list handling completed');
        break;

      case 'resources/read':
        await _handleResourceRead(sessionId, request);
        break;

      case 'resources/subscribe':
        await _handleResourceSubscribe(sessionId, request);
        break;

      case 'resources/unsubscribe':
        await _handleResourceUnsubscribe(sessionId, request);
        break;

      case 'resources/templates/list':
        await _handleResourceTemplatesList(sessionId, request);
        break;

      case 'prompts/list':
        await _handlePromptsList(sessionId, request);
        break;

      case 'prompts/get':
        await _handlePromptGet(sessionId, request);
        break;

      case 'cancel':
        await _handleCancelOperation(sessionId, request);
        break;

      case 'health/check':
        await _handleHealthCheck(sessionId, request);
        break;

      case 'sampling/createMessage':
        await _handleSamplingCreateMessage(sessionId, request);
        break;

      // OAuth 2.1 authentication methods (2025-03-26)
      case 'auth/authorize':
        await _handleOAuthAuthorize(sessionId, request);
        break;
        
      case 'auth/token':
        await _handleOAuthToken(sessionId, request);
        break;
        
      case 'auth/refresh':
        await _handleOAuthRefresh(sessionId, request);
        break;
        
      case 'auth/revoke':
        await _handleOAuthRevoke(sessionId, request);
        break;

      default:
        _sendErrorResponse(sessionId, request.id, ErrorCode.methodNotFound, 'Method not found');
    }
  }

  /// Handle initialize request
  Future<void> _handleInitialize(String sessionId, JsonRpcMessage request) async {
    // Handle protocol version negotiation using centralized logic
    final clientVersion = request.params?['protocolVersion'] as String?;
    final negotiatedVersion = McpProtocol.negotiateWithDateFallback(
      clientVersion, 
      supportedProtocolVersions
    );

    if (negotiatedVersion == null) {
      _sendErrorResponse(
          sessionId,
          request.id,
          ErrorCode.incompatibleVersion,
          'Unsupported protocol version: $clientVersion. Supported versions: ${supportedProtocolVersions.join(", ")}'
      );
      return;
    }

    // Store negotiated version in session
    final session = _sessions[sessionId];
    if (session != null) {
      session.negotiatedProtocolVersion = negotiatedVersion;

      // Store client capabilities
      if (request.params?['capabilities'] != null) {
        session.capabilities = request.params!['capabilities'];
      }

      // Handle roots if provided
      if (request.params?['roots'] != null) {
        final rootsData = request.params!['roots'] as List<dynamic>?;
        if (rootsData != null) {
          final roots = rootsData
              .map((r) => Root(
            uri: r['uri'],
            name: r['name'],
            description: r['description'],
          ))
              .toList();
          _storeClientRoots(sessionId, roots);
        }
      }
    }

    // Respond with server info and capabilities
    final response = {
      'protocolVersion': negotiatedVersion,
      'serverInfo': {
        'name': name,
        'version': version
      },
      'capabilities': capabilities.toJson(),
    };

    _sendResponse(sessionId, request.id, response);
  }

  /// Handle tools/list request
  Future<void> _handleToolsList(String sessionId, JsonRpcMessage request) async {
    _logger.debug('Tools listing requested');

    if (!capabilities.hasTools) {
      _logger.debug('Tools capability not supported');
      _sendErrorResponse(sessionId, request.id, ErrorCode.methodNotFound, 'Tools capability not supported');
      return;
    }

    try {
      final toolsList = _tools.values.map((tool) {
        _logger.debug('Processing tool: ${tool.name}');
        return tool.toJson();
      }).toList();

      _logger.debug('Sending tools list: $toolsList');
      _sendResponse(sessionId, request.id, {'tools': toolsList});
    } catch (e, stackTrace) {
      _logger.error('Error in tools list: $e');
      _logger.debug('Stacktrace: $stackTrace');
      _sendErrorResponse(
        sessionId,
        request.id,
        ErrorCode.internalError,
        'Internal server error processing tools',
        {'details': e.toString()},
      );
    }
  }

  /// Handle tools/call request
  Future<void> _handleToolCall(String sessionId, JsonRpcMessage request) async {
    if (!capabilities.hasTools) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.methodNotFound, 'Tools capability not supported');
      return;
    }

    final toolName = request.params?['name'];
    if (toolName == null || !_tools.containsKey(toolName)) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.toolNotFound, 'Tool not found: $toolName');
      return;
    }

    final handler = _toolHandlers[toolName]!;
    final arguments = request.params?['arguments'] ?? {};

    // Register operation
    final operationId = registerToolCall(toolName!, sessionId, request.id);

    try {
      // Call the handler with just the arguments
      final result = await handler(arguments);

      if (isOperationCancelled(operationId)) {
        _sendErrorResponse(sessionId, request.id, ErrorCode.operationCancelled, 'Operation cancelled by client');
      } else {
        _sendResponse(sessionId, request.id, result.toJson());
        _pendingOperations.remove(operationId);
      }
    } catch (e) {
      _pendingOperations.remove(operationId);
      _sendErrorResponse(
        sessionId,
        request.id,
        ErrorCode.internalError,
        'Tool execution error: $e',
        {'tool': toolName},
      );
    }
  }

  /// Handle resources/list request
  Future<void> _handleResourcesList(String sessionId, JsonRpcMessage request) async {
    _logger.debug('🔍 _handleResourcesList called - sessionId: $sessionId, requestId: ${request.id}');
    
    if (!capabilities.hasResources) {
      _logger.debug('❌ Resources capability not supported');
      _sendErrorResponse(sessionId, request.id, ErrorCode.methodNotFound, 'Resources capability not supported');
      return;
    }

    _logger.debug('✅ Resources capability supported, listing resources...');
    final resourcesList = _resources.values.map((resource) => resource.toJson()).toList();
    _logger.debug('📋 Found ${resourcesList.length} resources');

    _logger.debug('📤 Sending response for sessionId: $sessionId, requestId: ${request.id}');
    _sendResponse(sessionId, request.id, {'resources': resourcesList});
    _logger.debug('✅ Response sent successfully');
  }

  /// Handle resources/read request
  Future<void> _handleResourceRead(String sessionId, JsonRpcMessage request) async {
    if (!capabilities.hasResources) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.methodNotFound, 'Resources capability not supported');
      return;
    }

    final uri = request.params?['uri'];
    if (uri == null) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 'URI parameter is required');
      return;
    }

    // Check cache first (unless no_cache is specified)
    final noCache = request.params?['no_cache'] == true;
    if (!noCache) {
      final cached = getCachedResource(uri);
      if (cached != null) {
        _sendResponse(sessionId, request.id, cached.content.toJson());
        return;
      }
    }

    // Find matching handler
    ResourceHandler? handler;
    for (final entry in _resources.entries) {
      if (entry.key == uri || _uriMatches(uri, entry.key, entry.value.uriTemplate)) {
        handler = _resourceHandlers[entry.key];
        break;
      }
    }

    if (handler == null) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.resourceNotFound, 'Resource not found: $uri');
      return;
    }

    // Register operation for potential cancellation
    final operationId = Uuid().v4();
    _pendingOperations[operationId] = PendingOperation(
      id: operationId,
      sessionId: sessionId,
      type: 'resource:$uri',
      requestId: request.id.toString(),
    );

    try {
      final result = await handler(
        uri,
        request.params ?? {},
      );

      if (_pendingOperations[operationId]?.isCancelled ?? false) {
        _sendErrorResponse(
            sessionId,
            request.id,
            ErrorCode.operationCancelled,
            'Operation cancelled by client'
        );
      } else {
        // Cache result if cacheable
        final cacheable = request.params?['cacheable'] != false; // default true
        if (cacheable) {
          final maxAge = request.params?['cache_max_age'] as int?;
          final maxAgeDuration = maxAge != null ? Duration(seconds: maxAge) : null;
          cacheResource(uri, result, maxAgeDuration);
        }

        _sendResponse(sessionId, request.id, result.toJson());
        _pendingOperations.remove(operationId);
      }
    } catch (e) {
      _pendingOperations.remove(operationId);

      _sendErrorResponse(
        sessionId,
        request.id,
        ErrorCode.internalError,
        'Resource read error: $e',
        {'resource': uri},
      );
    }
  }

  /// Handle resources/templates/list request
  Future<void> _handleResourceTemplatesList(String sessionId, JsonRpcMessage request) async {
    if (!capabilities.hasResources) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.methodNotFound, 'Resources capability not supported');
      return;
    }

    // Filter resources with URI templates
    final resourceTemplates = _resources.values
        .where((resource) => resource.uriTemplate != null)
        .map((resource) => {
      'uriTemplate': resource.uri,
      'name': resource.name,
      'description': resource.description,
      'mimeType': resource.mimeType,
    })
        .toList();

    _sendResponse(sessionId, request.id, {'resourceTemplates': resourceTemplates});
  }

  /// Handle resources/subscribe request
  Future<void> _handleResourceSubscribe(String sessionId, JsonRpcMessage request) async {
    if (!capabilities.hasResources) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.methodNotFound, 'Resources capability not supported');
      return;
    }

    final uri = request.params?['uri'];
    if (uri == null) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 'URI parameter is required');
      return;
    }

    // Add subscription
    if (!_resourceSubscriptions.containsKey(uri)) {
      _resourceSubscriptions[uri] = <String>{};
    }
    _resourceSubscriptions[uri]!.add(sessionId);

    _sendResponse(sessionId, request.id, {'success': true});
  }

  /// Handle resources/unsubscribe request
  Future<void> _handleResourceUnsubscribe(String sessionId, JsonRpcMessage request) async {
    if (!capabilities.hasResources) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.methodNotFound, 'Resources capability not supported');
      return;
    }

    final uri = request.params?['uri'];
    if (uri == null) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 'URI parameter is required');
      return;
    }

    // Remove subscription
    _resourceSubscriptions[uri]?.remove(sessionId);
    if (_resourceSubscriptions[uri]?.isEmpty ?? false) {
      _resourceSubscriptions.remove(uri);
    }

    _sendResponse(sessionId, request.id, {'success': true});
  }

  /// Handle prompts/list request
  Future<void> _handlePromptsList(String sessionId, JsonRpcMessage request) async {
    if (!capabilities.hasPrompts) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.methodNotFound, 'Prompts capability not supported');
      return;
    }

    final promptsList = _prompts.values.map((prompt) => prompt.toJson()).toList();
    _sendResponse(sessionId, request.id, {'prompts': promptsList});
  }

  /// Handle prompts/get request
  Future<void> _handlePromptGet(String sessionId, JsonRpcMessage request) async {
    if (!capabilities.hasPrompts) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.methodNotFound, 'Prompts capability not supported');
      return;
    }

    final promptName = request.params?['name'];
    if (promptName == null || !_prompts.containsKey(promptName)) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.promptNotFound, 'Prompt not found: $promptName');
      return;
    }

    final handler = _promptHandlers[promptName]!;
    final arguments = request.params?['arguments'] ?? {};

    // Register operation for potential cancellation
    final operationId = Uuid().v4();
    _pendingOperations[operationId] = PendingOperation(
      id: operationId,
      sessionId: sessionId,
      type: 'prompt:$promptName',
      requestId: request.id.toString(),
    );

    try {
      final result = await handler(arguments);

      if (_pendingOperations[operationId]?.isCancelled ?? false) {
        _sendErrorResponse(
            sessionId,
            request.id,
            ErrorCode.operationCancelled,
            'Operation cancelled by client'
        );
      } else {
        _sendResponse(sessionId, request.id, result.toJson());
        _pendingOperations.remove(operationId);
      }
    } catch (e) {
      _pendingOperations.remove(operationId);
      _sendErrorResponse(
        sessionId,
        request.id,
        ErrorCode.internalError,
        'Prompt execution error: $e',
        {'prompt': promptName},
      );
    }
  }

  /// Handle cancel operation request
  Future<void> _handleCancelOperation(String sessionId, JsonRpcMessage request) async {
    final operationId = request.params?['id'];
    if (operationId == null) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 'Operation ID parameter is required');
      return;
    }

    final operation = _pendingOperations[operationId];
    if (operation == null) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 'Operation not found: $operationId');
      return;
    }

    // Check session ownership
    if (operation.sessionId != sessionId) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.unauthorized, 'Unauthorized to cancel this operation');
      return;
    }

    operation.isCancelled = true;
    _sendResponse(sessionId, request.id, {'cancelled': true});
  }

  /// Handle health check request
  Future<void> _handleHealthCheck(String sessionId, JsonRpcMessage request) async {
    final health = getHealth();
    _sendResponse(sessionId, request.id, health.toJson());
  }

  /// Handle sampling/createMessage request
  Future<void> _handleSamplingCreateMessage(String sessionId, JsonRpcMessage request) async {
    if (!capabilities.hasSampling) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.methodNotFound, 'Sampling capability not supported');
      return;
    }

    // Check client capabilities
    final session = _sessions[sessionId];
    if (session == null) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.internalError, 'Session not found');
      return;
    }

    final clientCapabilities = session.capabilities;
    final clientHasSampling = (clientCapabilities?['sampling'] != null);
    if (!clientHasSampling) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.methodNotFound, 'Client does not support sampling capability');
      return;
    }

    try {
      // Generate request ID
      final samplingRequestId = Uuid().v4();

      // Create completer for tracking the request
      final completer = Completer<Map<String, dynamic>>();

      // Register request tracker
      _pendingSamplingRequests[samplingRequestId] = completer;

      // Forward request to client
      _sendNotification(sessionId, 'sampling/createMessage', {
        'request_id': samplingRequestId,
        'params': request.params
      });

      // Wait for response (with timeout)
      final responseData = await completer.future.timeout(
          Duration(seconds: 60),
          onTimeout: () {
            _pendingSamplingRequests.remove(samplingRequestId);
            throw TimeoutException('Sampling request timed out');
          }
      );

      // Send response back to the original requester
      _sendResponse(sessionId, request.id, responseData);

    } catch (e) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.internalError, 'Sampling error: $e');
    }
  }

// Handler for sampling responses from clients
  Future<void> _handleSamplingResponse(String sessionId, JsonRpcMessage notification) async {
    final requestId = notification.params?['request_id'];
    if (requestId == null) {
      _logger.error('Received sampling response without request_id');
      return;
    }

    final completer = _pendingSamplingRequests[requestId];
    if (completer == null) {
      _logger.error('Received sampling response for unknown request: $requestId');
      return;
    }

    // Remove request tracker
    _pendingSamplingRequests.remove(requestId);

    // Extract response data
    final responseData = notification.params?['result'];
    if (responseData == null) {
      completer.completeError('No result in sampling response');
      return;
    }

    // Complete the response
    completer.complete(responseData);
  }

  /// Check if a URI matches a template pattern
  bool _uriMatches(String uri, String pattern, Map<String, dynamic>? template) {
    if (pattern == uri) return true;
    if (template == null) return false;

    // Simple template matching - could be enhanced for more complex patterns
    final patternParts = pattern.split('/');
    final uriParts = uri.split('/');

    if (patternParts.length != uriParts.length) return false;

    for (var i = 0; i < patternParts.length; i++) {
      final patternPart = patternParts[i];
      final uriPart = uriParts[i];

      if (patternPart.startsWith('{') && patternPart.endsWith('}')) {
        // This is a template parameter
        continue;
      } else if (patternPart != uriPart) {
        return false;
      }
    }

    return true;
  }

  /// Send a JSON-RPC response to specific session
  void _sendResponse(String sessionId, dynamic id, dynamic result, {String? batchId}) {
    _logger.debug('🚀 _sendResponse called - sessionId: $sessionId, id: $id');
    
    final session = _sessions[sessionId];
    if (session == null) {
      _logger.error('❌ Attempted to send response to non-existent session: $sessionId');
      _logger.debug('Available sessions: ${_sessions.keys.toList()}');
      return;
    }
    
    _logger.debug('✅ Session found, creating response...');

    final response = {
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    };

    // Check if this is part of a batch request
    if (batchId != null) {
      final tracker = _batchRequests[batchId];
      if (tracker != null) {
        tracker.addResponse(id, response);
        return; // Don't send individual response for batch items
      }
    }

    _logger.debug('📤 Calling transport.send() with response...');
    session.transport.send(response);
    _logger.debug('✅ transport.send() completed');
  }

  /// Send a JSON-RPC error response to specific session
  void _sendErrorResponse(String sessionId, dynamic id, int code, String message, [Map<String, dynamic>? data, String? batchId]) {
    final session = _sessions[sessionId];
    if (session == null) {
      _logger.error('Attempted to send error to non-existent session: $sessionId');
      return;
    }

    // Log the error
    _logger.error('Sending error response: $code - $message');
    if (data != null) {
      _logger.debug('Error data: $data');
    }

    final response = {
      'jsonrpc': '2.0',
      'id': id,
      'error': {
        'code': code,
        'message': message,
      },
    };

    if (data != null) {
      response['error']['data'] = data;
    }

    // Check if this is part of a batch request
    if (batchId != null) {
      final tracker = _batchRequests[batchId];
      if (tracker != null) {
        tracker.addResponse(id, response);
        return; // Don't send individual response for batch items
      }
    }

    try {
      session.transport.send(response);
    } catch (e) {
      _logger.error('Failed to send error response: $e');
      // Instead of crashing, just log the error
    }
  }
  
  /// Send a batch response (array of responses)
  void _sendBatchResponse(String sessionId, List<Map<String, dynamic>> responses) {
    final session = _sessions[sessionId];
    if (session == null) {
      _logger.error('Attempted to send batch response to non-existent session: $sessionId');
      return;
    }
    
    try {
      session.transport.send(responses);
      _logger.debug('Sent batch response with ${responses.length} items');
    } catch (e) {
      _logger.error('Failed to send batch response: $e');
    }
  }

  /// Send a JSON-RPC notification to specific session
  void _sendNotification(String sessionId, String method, Map<String, dynamic> params) {
    final session = _sessions[sessionId];
    if (session == null) {
      _logger.error('Attempted to send notification to non-existent session: $sessionId');
      return;
    }

    final notification = {
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    };

    session.transport.send(notification);
  }

  /// Broadcast a notification to all connected sessions
  void _broadcastNotification(String method, Map<String, dynamic> params) {
    final notification = {
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    };

    for (final session in _sessions.values) {
      session.transport.send(notification);
    }
  }

  /// Get all registered tools
  @override
  List<Tool> getTools() => _tools.values.toList();

  /// Get all registered resources
  @override
  List<Resource> getResources() => _resources.values.toList();

  /// Get all registered prompts
  @override
  List<Prompt> getPrompts() => _prompts.values.toList();

  /// Get all active sessions
  @override
  List<ClientSession> getSessions() => _sessions.values.toList();
  
  /// Cancel an operation
  void cancelOperation(String operationId) {
    final operation = _pendingOperations[operationId];
    if (operation != null) {
      operation.isCancelled = true;
      // Don't remove from _pendingOperations yet, keep for status checking
      
      // Notify the session about cancellation
      _sendNotification(operation.sessionId, 'notifications/cancelled', {
        'operationId': operationId,
        'reason': 'Operation cancelled by server',
      });
      
      _logger.info('Cancelled operation: $operationId');
    }
  }
  
  /// Disconnect a specific session
  void disconnectSession(String sessionId) {
    final session = _sessions[sessionId];
    if (session != null) {
      // Clean up session resources
      _sessions.remove(sessionId);
      
      // Cancel all pending operations for this session
      final operationsToCancel = _pendingOperations.values
          .where((op) => op.sessionId == sessionId)
          .toList();
      
      for (final operation in operationsToCancel) {
        cancelOperation(operation.id);
      }
      
      // Close the transport if it has a close method
      try {
        if (session.transport != null) {
          (session.transport as dynamic).close();
        }
      } catch (e) {
        _logger.error('Error closing transport for session $sessionId: $e');
      }
      
      _logger.info('Disconnected session: $sessionId');
    }
  }
  
  /// Call a tool with the given arguments
  Future<CallToolResult> callTool(String name, Map<String, dynamic> arguments) async {
    final tool = _tools[name];
    if (tool == null) {
      throw McpError('Tool not found: $name');
    }
    
    // Execute the tool handler
    final handler = _toolHandlers[name];
    if (handler == null) {
      throw McpError('No handler registered for tool: $name');
    }
    
    return await handler(arguments);
  }
  
  /// Call a tool with cancellation support
  Future<CallToolResult> callToolWithCancellation(
    String name, 
    Map<String, dynamic> arguments,
    String operationId,
  ) async {
    // Register the operation
    final operation = PendingOperation(
      id: operationId,
      sessionId: 'system', // Use a system session for direct calls
      type: 'tool:$name',
    );
    _pendingOperations[operationId] = operation;
    
    try {
      // Check if cancelled before starting
      if (operation.isCancelled) {
        throw McpError('Operation cancelled');
      }
      
      return await callTool(name, arguments);
    } finally {
      _pendingOperations.remove(operationId);
    }
  }
  
  /// Add a tool with progress support
  void addToolWithProgress(
    String name,
    String description,
    Map<String, dynamic> inputSchema,
    Future<CallToolResult> Function(
      Map<String, dynamic> arguments, {
      Function(double, String)? onProgress,
    }) handler,
  ) {
    addTool(
      name: name,
      description: description,
      inputSchema: inputSchema,
      handler: (arguments) async {
        // Placeholder - will be replaced below
        return CallToolResult(content: []);
      },
    );
    
    // Wrap the handler to support progress
    _toolHandlers[name] = (arguments) async {
      // Create an operation ID for progress tracking
      final operationId = const Uuid().v4();
      
      return await handler(arguments, onProgress: (progress, message) {
        notifyProgress(operationId, progress, message);
      });
    };
  }
  
  /// Read a resource by URI
  Future<ReadResourceResult> readResource(String uri) async {
    final resource = _resources[uri];
    if (resource == null) {
      // Check if it matches a template
      for (final template in _resourceTemplates.values) {
        // Simple template matching (could be improved)
        if (_matchesTemplate(uri, template.uriTemplate)) {
          // Return a mock result for now
          return ReadResourceResult(contents: [
            ResourceContentInfo(
              uri: uri,
              mimeType: template.mimeType,
              text: 'Template-based resource content',
            ),
          ]);
        }
      }
      
      throw McpError('Resource not found: $uri');
    }
    
    // Get the resource handler
    final handler = _resourceHandlers[uri];
    if (handler == null) {
      throw McpError('No handler registered for resource: $uri');
    }
    
    return await handler(uri, {});
  }
  
  /// Add a resource template
  void addResourceTemplate(ResourceTemplate template) {
    _resourceTemplates[template.uriTemplate] = template;
    
    if (capabilities.resourcesListChanged) {
      _broadcastNotification('notifications/resources/list_changed', {});
    }
  }
  
  /// Simple template matching helper
  bool _matchesTemplate(String uri, String template) {
    // Convert template to regex (simple implementation)
    final pattern = template
        .replaceAll('{', '(?<')
        .replaceAll('}', '>[^/]+)')
        .replaceAll('/', '\\/');
    
    final regex = RegExp('^$pattern\$');
    return regex.hasMatch(uri);
  }
  
  /// Add a root to the server
  void addRoot(Root root) {
    if (_roots.any((r) => r.uri == root.uri)) {
      throw McpError('Root with URI "${root.uri}" already exists');
    }
    
    _roots.add(root);
    
    // Notify clients about root changes
    if (isConnected) {
      _broadcastNotification('notifications/roots/list_changed', {
        'roots': _roots.map((r) => r.toJson()).toList(),
      });
    }
  }
  
  /// Remove a root from the server
  void removeRoot(String uri) {
    if (!_roots.any((r) => r.uri == uri)) {
      throw McpError('Root with URI "$uri" does not exist');
    }
    
    _roots.removeWhere((r) => r.uri == uri);
    
    // Notify clients about root changes
    if (isConnected) {
      _broadcastNotification('notifications/roots/list_changed', {
        'roots': _roots.map((r) => r.toJson()).toList(),
      });
    }
  }
  
  /// Get all server roots
  List<Root> listRoots() {
    return List<Root>.unmodifiable(_roots);
  }
  
  /// Enable rate limiting with optional configuration
  void enableRateLimiting({
    RateLimitConfig? defaultConfig,
    Map<String, RateLimitConfig>? methodConfigs,
  }) {
    _rateLimiter = RateLimiter(
      defaultConfig: defaultConfig,
      methodConfigs: methodConfigs,
    );
    _logger.info('Rate limiting enabled');
  }
  
  /// Configure rate limit for specific method
  void configureMethodRateLimit(String method, RateLimitConfig config) {
    _rateLimiter ??= RateLimiter();
    _rateLimiter!.configureMethod(method, config);
  }
  
  /// Disable rate limiting
  void disableRateLimiting() {
    _rateLimiter = null;
    _logger.info('Rate limiting disabled');
  }
  
  /// Get rate limit statistics
  Map<String, dynamic> getRateLimitStats() {
    if (_rateLimiter == null) {
      return {'enabled': false};
    }
    
    return {
      'enabled': true,
      'limits': _rateLimiter!.getStats(),
    };
  }
  
  /// Update resource metrics
  void _updateResourceMetrics() {
    _metricsCollector.gauge('mcp_tools_registered').set(_tools.length.toDouble());
    _metricsCollector.gauge('mcp_resources_registered').set(_resources.length.toDouble());
    _metricsCollector.gauge('mcp_prompts_registered').set(_prompts.length.toDouble());
  }
  
  /// Get complete metrics
  Map<String, dynamic> getMetrics() {
    return _metricsCollector.toJson();
  }
}


/// Error class for MCP-related errors
class McpError implements Exception {
  final String message;

  McpError(this.message);

  @override
  String toString() => 'McpError: $message';
}

/// JSON-RPC message
class JsonRpcMessage {
  final String jsonrpc;
  final dynamic id;
  final String? method;
  final Map<String, dynamic>? params;
  final dynamic result;
  final Map<String, dynamic>? error;
  String sessionId = '';
  String? batchId;

  bool get isNotification => id == null && method != null;
  bool get isRequest => id != null && method != null;
  bool get isResponse => id != null && (result != null || error != null);

  JsonRpcMessage({
    required this.jsonrpc,
    this.id,
    this.method,
    this.params,
    this.result,
    this.error,
  });

  factory JsonRpcMessage.fromJson(Map<String, dynamic> json) {
    return JsonRpcMessage(
      jsonrpc: json['jsonrpc'],
      id: json['id'],
      method: json['method'],
      params: json['params'] != null ? Map<String, dynamic>.from(json['params']) : null,
      result: json['result'],
      error: json['error'] != null ? Map<String, dynamic>.from(json['error']) : null,
    );
  }
}

/// Interface for server to expose key functionality for testing
abstract class ServerInterface {
  /// Name of the MCP server
  String get name;

  /// Version of the MCP server implementation
  String get version;

  /// Server capabilities configuration
  ServerCapabilities get capabilities;

  /// Stream of session connection events
  Stream<ClientSession> get onConnect;

  /// Stream of session disconnection events
  Stream<ClientSession> get onDisconnect;

  /// Get all registered tools
  List<Tool> getTools();

  /// Get all registered resources
  List<Resource> getResources();

  /// Get all registered prompts
  List<Prompt> getPrompts();

  /// Get all active sessions
  List<ClientSession> getSessions();

  /// Get server health information
  ServerHealth getHealth();

  /// Add a tool to the server
  void addTool({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required ToolHandler handler,
  });

  /// Add a resource to the server
  void addResource({
    required String uri,
    required String name,
    required String description,
    required String mimeType,
    Map<String, dynamic>? uriTemplate,
    required ResourceHandler handler,
  });

  /// Add a prompt to the server
  void addPrompt({
    required String name,
    required String description,
    required List<PromptArgument> arguments,
    required PromptHandler handler,
  });

  /// Remove a tool from the server
  void removeTool(String name);

  /// Remove a resource from the server
  void removeResource(String uri);

  /// Remove a prompt from the server
  void removePrompt(String name);
}

// Additional OAuth methods for Server class
extension OAuthServerMethods on Server {
  /// Enable OAuth authentication with the specified validator
  void enableAuthentication(TokenValidator validator, {
    List<String> publicPaths = const ['/health', '/ping'],
    List<String> defaultRequiredScopes = const [],
    bool strictMode = true,
  }) {
    _authMiddleware = AuthMiddleware(
      validator: validator,
      publicPaths: publicPaths,
      defaultRequiredScopes: defaultRequiredScopes,
      strictMode: strictMode,
    );
    _logger.info('OAuth authentication enabled');
  }
  
  /// Disable OAuth authentication
  void disableAuthentication() {
    _authMiddleware = null;
    _logger.info('OAuth authentication disabled');
  }
  
  /// Check if authentication is enabled
  bool get isAuthenticationEnabled => _authMiddleware != null;
  
  /// Authenticate a request using the configured auth middleware
  Future<AuthResult?> _authenticateRequest(String sessionId, JsonRpcMessage request) async {
    if (_authMiddleware == null) return null;
    
    // Extract authorization token from request params or session
    final session = _sessions[sessionId];
    final token = request.params?['authorization'] as String? ?? 
                  session?.authToken;
    
    if (token == null) {
      return const AuthResult.failure(error: 'No authorization token provided');
    }
    
    // Get required scopes for this method
    final requiredScopes = McpMethodAuth.getRequiredScopes(request.method ?? '');
    
    // Validate token
    return await _authMiddleware!.validator.validateToken(
      token, 
      requiredScopes: requiredScopes.isNotEmpty ? requiredScopes : null
    );
  }
  
  /// Handle OAuth authorization request
  Future<void> _handleOAuthAuthorize(String sessionId, JsonRpcMessage request) async {
    final responseType = request.params?['response_type'] as String?;
    final clientId = request.params?['client_id'] as String?;
    final redirectUri = request.params?['redirect_uri'] as String?;
    final scope = request.params?['scope'] as String?;
    final state = request.params?['state'] as String?;
    final codeChallenge = request.params?['code_challenge'] as String?;
    final codeChallengeMethod = request.params?['code_challenge_method'] as String?;
    
    if (responseType != 'code') {
      _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 
          'Only authorization code flow is supported');
      return;
    }
    
    if (clientId == null || redirectUri == null) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 
          'client_id and redirect_uri are required');
      return;
    }
    
    // Generate authorization code
    final authCode = const Uuid().v4();
    final scopes = scope?.split(' ') ?? [];
    
    // Store authorization code with expiration (10 minutes)
    final codeData = {
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'scope': scopes,
      'code_challenge': codeChallenge,
      'code_challenge_method': codeChallengeMethod,
      'expires_at': DateTime.now().add(Duration(minutes: 10)).millisecondsSinceEpoch,
    };
    
    // In a real implementation, you would store this securely
    // For demo purposes, we'll store it in the session
    final session = _sessions[sessionId];
    if (session != null) {
      session.pendingAuthCodes ??= {};
      session.pendingAuthCodes![authCode] = codeData;
    }
    
    final response = {
      'authorization_code': authCode,
      'redirect_uri': redirectUri,
      'state': state,
      'expires_in': 600, // 10 minutes
    };
    
    _sendResponse(sessionId, request.id, response);
  }
  
  /// Handle OAuth token request
  Future<void> _handleOAuthToken(String sessionId, JsonRpcMessage request) async {
    final grantType = request.params?['grant_type'] as String?;
    
    switch (grantType) {
      case 'authorization_code':
        await _handleAuthorizationCodeGrant(sessionId, request);
        break;
      case 'client_credentials':
        await _handleClientCredentialsGrant(sessionId, request);
        break;
      case 'refresh_token':
        await _handleRefreshTokenGrant(sessionId, request);
        break;
      default:
        _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 
            'Unsupported grant type: $grantType');
    }
  }
  
  /// Handle authorization code grant
  Future<void> _handleAuthorizationCodeGrant(String sessionId, JsonRpcMessage request) async {
    final code = request.params?['code'] as String?;
    final clientId = request.params?['client_id'] as String?;
    // clientSecret is not used in this implementation
    final redirectUri = request.params?['redirect_uri'] as String?;
    final codeVerifier = request.params?['code_verifier'] as String?;
    
    if (code == null || clientId == null || redirectUri == null) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 
          'code, client_id, and redirect_uri are required');
      return;
    }
    
    // Find the session with this authorization code
    Map<String, dynamic>? codeData;
    for (final session in _sessions.values) {
      if (session.pendingAuthCodes?.containsKey(code) == true) {
        codeData = session.pendingAuthCodes![code];
        session.pendingAuthCodes!.remove(code); // Use code only once
        break;
      }
    }
    
    if (codeData == null) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 
          'Invalid or expired authorization code');
      return;
    }
    
    // Verify code data
    if (codeData['client_id'] != clientId || 
        codeData['redirect_uri'] != redirectUri) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 
          'Code verification failed');
      return;
    }
    
    // Check expiration
    final expiresAt = codeData['expires_at'] as int?;
    if (expiresAt != null && DateTime.now().millisecondsSinceEpoch > expiresAt) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 
          'Authorization code expired');
      return;
    }
    
    // Verify PKCE if provided
    if (codeData['code_challenge'] != null) {
      if (codeVerifier == null) {
        _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 
            'code_verifier required for PKCE');
        return;
      }
      
      // Verify code challenge (simplified verification)
      // In production, use proper SHA256 hashing
      final method = codeData['code_challenge_method'] as String? ?? 'S256';
      if (method == 'S256') {
        // Simplified verification - in production use crypto library
        final expectedChallenge = codeData['code_challenge'];
        if (expectedChallenge != codeVerifier) {
          _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 
              'Invalid code verifier');
          return;
        }
      }
    }
    
    // Generate tokens
    final accessToken = const Uuid().v4();
    final refreshToken = const Uuid().v4();
    final scopes = (codeData['scope'] as List<dynamic>?)?.cast<String>() ?? [];
    
    // Store token data
    final session = _sessions[sessionId];
    if (session != null) {
      session.accessTokens ??= {};
      session.accessTokens![accessToken] = {
        'client_id': clientId,
        'scope': scopes,
        'expires_at': DateTime.now().add(Duration(hours: 1)).millisecondsSinceEpoch,
        'refresh_token': refreshToken,
      };
    }
    
    final response = {
      'access_token': accessToken,
      'token_type': 'Bearer',
      'expires_in': 3600,
      'refresh_token': refreshToken,
      'scope': scopes.join(' '),
    };
    
    _sendResponse(sessionId, request.id, response);
  }
  
  /// Handle client credentials grant
  Future<void> _handleClientCredentialsGrant(String sessionId, JsonRpcMessage request) async {
    final clientId = request.params?['client_id'] as String?;
    final clientSecret = request.params?['client_secret'] as String?;
    final scope = request.params?['scope'] as String?;
    
    if (clientId == null || clientSecret == null) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 
          'client_id and client_secret are required');
      return;
    }
    
    // Validate client credentials (simplified)
    // In production, verify against secure client registry
    if (!_validateClientCredentials(clientId, clientSecret)) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.unauthorized, 
          'Invalid client credentials');
      return;
    }
    
    // Generate access token
    final accessToken = const Uuid().v4();
    final scopes = scope?.split(' ') ?? [];
    
    // Store token data
    final session = _sessions[sessionId];
    if (session != null) {
      session.accessTokens ??= {};
      session.accessTokens![accessToken] = {
        'client_id': clientId,
        'scope': scopes,
        'expires_at': DateTime.now().add(Duration(hours: 1)).millisecondsSinceEpoch,
        'grant_type': 'client_credentials',
      };
    }
    
    final response = {
      'access_token': accessToken,
      'token_type': 'Bearer',
      'expires_in': 3600,
      'scope': scopes.join(' '),
    };
    
    _sendResponse(sessionId, request.id, response);
  }
  
  /// Handle refresh token grant
  Future<void> _handleRefreshTokenGrant(String sessionId, JsonRpcMessage request) async {
    final refreshToken = request.params?['refresh_token'] as String?;
    // clientId and clientSecret are not used in this implementation
    
    if (refreshToken == null) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 
          'refresh_token is required');
      return;
    }
    
    // Find token data by refresh token
    Map<String, dynamic>? tokenData;
    String? oldAccessToken;
    
    for (final session in _sessions.values) {
      if (session.accessTokens != null) {
        for (final entry in session.accessTokens!.entries) {
          if (entry.value['refresh_token'] == refreshToken) {
            tokenData = entry.value;
            oldAccessToken = entry.key;
            break;
          }
        }
      }
      if (tokenData != null) break;
    }
    
    if (tokenData == null) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 
          'Invalid refresh token');
      return;
    }
    
    // Generate new access token
    final newAccessToken = const Uuid().v4();
    final scopes = (tokenData['scope'] as List<dynamic>?)?.cast<String>() ?? [];
    
    // Update token data
    final session = _sessions[sessionId];
    if (session != null && oldAccessToken != null) {
      session.accessTokens!.remove(oldAccessToken);
      session.accessTokens![newAccessToken] = {
        'client_id': tokenData['client_id'],
        'scope': scopes,
        'expires_at': DateTime.now().add(Duration(hours: 1)).millisecondsSinceEpoch,
        'refresh_token': refreshToken,
      };
    }
    
    final response = {
      'access_token': newAccessToken,
      'token_type': 'Bearer',
      'expires_in': 3600,
      'scope': scopes.join(' '),
    };
    
    _sendResponse(sessionId, request.id, response);
  }
  
  /// Handle OAuth revoke request
  Future<void> _handleOAuthRevoke(String sessionId, JsonRpcMessage request) async {
    final token = request.params?['token'] as String?;
    // Note: token_type_hint parameter is ignored in this implementation
    
    if (token == null) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams, 
          'token is required');
      return;
    }
    
    // Find and revoke the token
    bool tokenRevoked = false;
    
    for (final session in _sessions.values) {
      // Check access tokens
      if (session.accessTokens?.remove(token) != null) {
        tokenRevoked = true;
        break;
      }
      
      // Check refresh tokens
      if (session.accessTokens != null) {
        final toRemove = <String>[];
        for (final entry in session.accessTokens!.entries) {
          if (entry.value['refresh_token'] == token) {
            toRemove.add(entry.key);
          }
        }
        for (final key in toRemove) {
          session.accessTokens!.remove(key);
          tokenRevoked = true;
        }
      }
    }
    
    // Log token revocation status for debugging
    _logger.fine('Token revocation attempted: ${tokenRevoked ? "success" : "not found"}');
    
    // Always return success for security (don't reveal token validity)
    _sendResponse(sessionId, request.id, {'revoked': true});
  }
  
  /// Handle OAuth refresh request (alias for refresh token grant)
  Future<void> _handleOAuthRefresh(String sessionId, JsonRpcMessage request) async {
    // Set grant_type if not provided
    final modifiedParams = Map<String, dynamic>.from(request.params ?? {});
    modifiedParams['grant_type'] = 'refresh_token';
    
    final modifiedRequest = JsonRpcMessage(
      jsonrpc: request.jsonrpc,
      id: request.id,
      method: 'auth/token',
      params: modifiedParams,
    );
    modifiedRequest.sessionId = request.sessionId;
    modifiedRequest.batchId = request.batchId;
    
    await _handleOAuthToken(sessionId, modifiedRequest);
  }
  
  /// Validate client credentials (simplified implementation)
  bool _validateClientCredentials(String clientId, String clientSecret) {
    // In production, this would check against a secure client registry
    // For demo purposes, accept any non-empty credentials
    return clientId.isNotEmpty && clientSecret.isNotEmpty;
  }

}