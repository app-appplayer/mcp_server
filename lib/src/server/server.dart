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

/// Type definition for completion handler functions (spec
/// `completion/complete`).
///
/// [ref] identifies which prompt or resource template the completion is
/// for. Spec shapes:
/// - `{ "type": "ref/prompt", "name": "..." }`
/// - `{ "type": "ref/resource", "uri": "..." }`
///
/// [argument] is `{ name, value }` — the partial value being completed.
/// [context] holds previously-resolved arguments (spec 2025-06-18).
///
/// Returns `{ values, total?, hasMore? }`. `values` MUST have ≤ 100 entries.
typedef CompletionHandler = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> ref,
  Map<String, dynamic> argument,
  Map<String, dynamic>? context,
);

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

  /// Registered completion handlers, keyed by `<refType>:<refKey>` where
  /// refType is `prompt` or `resource` and refKey is the prompt name or
  /// resource template URI. Plus a fallback `*` handler for any ref.
  final Map<String, CompletionHandler> _completionHandlers = {};
  
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

  /// Optional listener for client → server `notifications/progress`.
  /// Signature: (sessionId, params) where params follows the spec
  /// `{ progressToken, progress, total?, message? }`.
  void Function(String sessionId, Map<String, dynamic> params)? _onClientProgress;
  set onClientProgress(
      void Function(String sessionId, Map<String, dynamic> params)? handler) {
    _onClientProgress = handler;
  }

  /// Tracks server-initiated outbound JSON-RPC requests (e.g.
  /// `sampling/createMessage`, `roots/list`, `elicitation/create`) so the
  /// matching client response can complete the awaiting future. Keyed by
  /// the outbound request id we generate.
  final Map<String, Completer<dynamic>> _pendingOutboundRequests = {};

  /// Counter used to mint unique outbound request ids.
  int _outboundRequestSeq = 0;
  

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

  /// Stream controllers for resource subscription events
  final _resourceSubscribedController = StreamController<String>.broadcast();
  final _resourceUnsubscribedController = StreamController<String>.broadcast();

  /// Server roots
  final List<Root> _roots = [];
  
  /// Rate limiter
  RateLimiter? _rateLimiter;
  
  /// Authentication middleware
  AuthMiddleware? _authMiddleware;
  _ProtectedResourceMetadata? _protectedResource;
  
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

  /// Stream of resource subscription events (emits resource URI)
  Stream<String> get onResourceSubscribed => _resourceSubscribedController.stream;

  /// Stream of resource unsubscription events (emits resource URI)
  Stream<String> get onResourceUnsubscribed => _resourceUnsubscribedController.stream;

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

    // Determine if this is a multi-session transport (StreamableHTTP)
    final isMultiSessionTransport = transport is StreamableHttpServerTransport;

    // Create initial session only for single-session transports (for backward compatibility)
    String? initialSessionId;
    if (!isMultiSessionTransport) {
      initialSessionId = _createSession(transport);
    }

    try {
      transport.onMessage.listen((rawMessage) {
        // Extract session ID from message metadata (if present)
        String? messageSessionId;

        if (rawMessage is Map && rawMessage.containsKey('_sessionId')) {
          // Multi-session transport: use session ID from message
          messageSessionId = rawMessage['_sessionId'] as String;

          // Create session if it doesn't exist
          if (!_sessions.containsKey(messageSessionId)) {
            _logger.debug('Creating new session from transport message: $messageSessionId');
            final session = ClientSession(
              id: messageSessionId,
              connectedAt: DateTime.now(),
              transport: transport,  // IMPORTANT: Set transport reference for sending responses
            );
            session.capabilities = {};
            _sessions[messageSessionId] = session;

            // Update metrics
            _metricsCollector.gauge('mcp_connections_active').set(_sessions.length.toDouble());
            _metricsCollector.counter('mcp_connections_total').increment();
          }
        } else {
          // Single-session transport: use initial session ID
          messageSessionId = initialSessionId;
        }

        if (messageSessionId == null) {
          _logger.error('No session ID available for message: $rawMessage');
          return;
        }

        _handleMessage(messageSessionId, rawMessage);
      }, onError: (error) {
        _logger.error('Error from transport message stream: $error');
      });

      transport.onClose.then((_) {
        // Remove all sessions associated with this transport
        final sessionIds = List<String>.from(_sessions.keys);
        for (final sid in sessionIds) {
          _removeSession(sid);
        }
        _onDisconnect();
      }).catchError((error) {
        _logger.error('Transport close error: $error');
        // Remove all sessions associated with this transport
        final sessionIds = List<String>.from(_sessions.keys);
        for (final sid in sessionIds) {
          _removeSession(sid);
        }
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
    String sessionId;

    // Generate a new session ID
    // Note: StreamableHTTP now manages multiple sessions internally
    sessionId = Uuid().v4();
    _logger.debug('Generated new session ID: $sessionId');

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
    for (final subscribers in _resourceSubscriptions.values) {
      subscribers.remove(sessionId);
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

  /// Check if session exists
  bool hasSession(String sessionId) {
    return _sessions.containsKey(sessionId);
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
      _broadcastNotification('notifications/tools/list_changed', {});
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

    // Auto-detect template URIs (containing {param} placeholders)
    if (uriTemplate == null && uri.contains('{') && uri.contains('}')) {
      uriTemplate = {'isTemplate': true};
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
      _broadcastNotification('notifications/resources/list_changed', {});
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
      _broadcastNotification('notifications/prompts/list_changed', {});
    }

    // Emit change event
    _promptsChangedController.add(null);
  }

  /// Register a completion handler for argument autocompletion (spec
  /// `completion/complete`).
  ///
  /// [refType] is `'prompt'` or `'resource'`. [refKey] is the prompt name
  /// or resource template URI; pass `'*'` to register a wildcard handler
  /// that catches any ref of the given type. Pass [refType] = `'*'` for
  /// a global fallback.
  ///
  /// The handler receives the spec `ref` map, the `argument` map
  /// (`{ name, value }`), and the optional `context.arguments` map of
  /// previously-resolved arguments.
  ///
  /// Returns a map with spec shape `{values, total?, hasMore?}` where
  /// `values` is `List&lt;String&gt;` clipped to 100 entries.
  void addCompletion({
    required String refType,
    required String refKey,
    required CompletionHandler handler,
  }) {
    final key = refType == '*' ? '*' : '$refType:$refKey';
    _completionHandlers[key] = handler;
  }

  /// Remove a completion handler.
  void removeCompletion({required String refType, required String refKey}) {
    final key = refType == '*' ? '*' : '$refType:$refKey';
    _completionHandlers.remove(key);
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
      _broadcastNotification('notifications/tools/list_changed', {});
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
      _broadcastNotification('notifications/resources/list_changed', {});
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
      _broadcastNotification('notifications/prompts/list_changed', {});
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
  /// 
  /// [uri] The URI of the updated resource
  /// [content] Optional resource content. If provided, sends ResourceContentInfo format.
  ///           If omitted, sends only URI (MCP 2025-03-26 standard compliant).
  void notifyResourceUpdated(String uri, {ResourceContent? content}) {
    // Invalidate cache
    _resourceCache.remove(uri);

    if (!isConnected || !capabilities.hasResources) return;

    final subscribers = _resourceSubscriptions[uri];
    if (subscribers == null || subscribers.isEmpty) return;

    // Build notification based on whether content is provided
    final Map<String, dynamic> notification;
    if (content != null) {
      // Extended format with ResourceContentInfo structure
      notification = {
        'uri': uri,
        'content': {
          'uri': uri,
          'text': content.text,
          'blob': content.blob,
          'mimeType': content.mimeType,
        },
      };
    } else {
      // Standard MCP 2025-03-26 format (URI only)
      notification = {
        'uri': uri,
      };
    }

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
    _resourceSubscribedController.close();
    _resourceUnsubscribedController.close();
  }

  /// Handle incoming messages from the transport.
  ///
  /// JSON-RPC batching was removed in MCP 2025-06-18 (PR #416). A batch
  /// array on the wire is treated as an invalid request — clients must
  /// send individual messages.
  void _handleMessage(String sessionId, dynamic rawMessage) {
    try {
      final parsed = rawMessage is String ? jsonDecode(rawMessage) : rawMessage;

      if (parsed is List) {
        _sendErrorResponse(sessionId, null, ErrorCode.invalidRequest,
            'JSON-RPC batching is not supported (removed in MCP 2025-06-18)');
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
      } else if (message.isResponse) {
        // Response to a server-initiated outbound request (sampling /
        // roots / elicitation). Match by outbound id and complete the
        // pending Completer.
        incrementMetric('messages.responses');
        _handleOutboundResponse(message);
      } else {
        incrementMetric('messages.invalid');
        _sendErrorResponse(sessionId, message.id, ErrorCode.invalidRequest, 'Invalid request');
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

      case 'notifications/cancelled':
        // Spec: client cancels an in-flight request. params: { requestId, reason? }.
        final cancelRequestId = notification.params?['requestId']?.toString();
        if (cancelRequestId != null) {
          for (final op in _pendingOperations.values) {
            if (op.requestId == cancelRequestId && op.sessionId == sessionId) {
              op.isCancelled = true;
              break;
            }
          }
        }
        break;

      case 'notifications/progress':
        // Spec: client reports progress on an in-flight server-initiated
        // request. params: { progressToken, progress, total?, message? }.
        // Forwarded to any registered progress listener; default no-op.
        _onClientProgress?.call(sessionId, notification.params ?? const {});
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

      case 'completion/complete':
        await _handleCompletionComplete(sessionId, request);
        break;

      // Standard MCP methods
      case 'logging/setLevel':
        await _handleLoggingSetLevel(sessionId, request);
        break;

      case 'ping':
        await _handlePing(sessionId, request);
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
      session.isInitialized = true; // Mark session as initialized

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
        // Cache result only when explicitly opted in. Default is OFF so
        // mutable resources (canonical state, live data, sensor reads)
        // are never silently served stale. Consumers that benefit from
        // caching pass `cacheable: true` and optionally
        // `cache_max_age: <seconds>`.
        final cacheable = request.params?['cacheable'] == true;
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

    // Emit subscription event
    _resourceSubscribedController.add(uri);

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

    // Emit unsubscription event
    _resourceUnsubscribedController.add(uri);

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

  /// Handle completion/complete request (spec): argument autocompletion
  /// for a registered prompt argument or resource-template argument.
  Future<void> _handleCompletionComplete(
      String sessionId, JsonRpcMessage request) async {
    if (!capabilities.hasCompletions) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.methodNotFound,
          'Completions capability not supported');
      return;
    }

    final ref = request.params?['ref'];
    final argument = request.params?['argument'];
    if (ref is! Map<String, dynamic> || argument is! Map<String, dynamic>) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.invalidParams,
          '`ref` and `argument` are required');
      return;
    }
    final context = request.params?['context'] as Map<String, dynamic>?;

    // Resolve handler key. Prefer the most-specific registered handler:
    //   1. exact ref (e.g. `prompt:greet` / `resource:file:///{path}`)
    //   2. wildcard for ref type (`prompt:*` / `resource:*`)
    //   3. global fallback (`*`)
    String? key;
    final refType = ref['type']?.toString() ?? '';
    if (refType == 'ref/prompt' || refType == 'prompt') {
      final name = ref['name']?.toString() ?? '';
      if (_completionHandlers.containsKey('prompt:$name')) {
        key = 'prompt:$name';
      } else if (_completionHandlers.containsKey('prompt:*')) {
        key = 'prompt:*';
      }
    } else if (refType == 'ref/resource' || refType == 'resource') {
      final uri = ref['uri']?.toString() ?? '';
      if (_completionHandlers.containsKey('resource:$uri')) {
        key = 'resource:$uri';
      } else if (_completionHandlers.containsKey('resource:*')) {
        key = 'resource:*';
      }
    }
    key ??= _completionHandlers.containsKey('*') ? '*' : null;

    if (key == null) {
      // Spec allows responding with empty completion when no handler.
      _sendResponse(sessionId, request.id, {
        'completion': {
          'values': <String>[],
          'total': 0,
          'hasMore': false,
        }
      });
      return;
    }

    try {
      final result =
          await _completionHandlers[key]!(ref, argument, context);
      // Coerce to spec shape if handler returned a partial map.
      final completion = result['completion'] is Map
          ? Map<String, dynamic>.from(result['completion'] as Map)
          : Map<String, dynamic>.from(result);
      final values = (completion['values'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[];
      // Spec: values MUST have ≤ 100 entries.
      final clipped = values.length > 100 ? values.sublist(0, 100) : values;
      _sendResponse(sessionId, request.id, {
        'completion': {
          'values': clipped,
          if (completion['total'] is int) 'total': completion['total'],
          if (completion['hasMore'] is bool) 'hasMore': completion['hasMore'],
        }
      });
    } catch (e) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.internalError,
          'Completion error: $e');
    }
  }

  /// Server-initiated request: ask the connected client's LLM to
  /// generate a completion (spec `sampling/createMessage`).
  ///
  /// [params] follows the spec `CreateMessageRequest.params` shape:
  /// `messages`, `maxTokens` (required), plus optional `modelPreferences`,
  /// `systemPrompt`, `includeContext`, `temperature`, `stopSequences`,
  /// `metadata`.
  ///
  /// Returns the spec `CreateMessageResult` map (`role`, `content`,
  /// `model`, optional `stopReason`).
  ///
  /// The client must advertise the `sampling` capability during
  /// initialize; otherwise this throws [McpError] with methodNotFound.
  Future<Map<String, dynamic>> requestClientSampling(
    String sessionId,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final session = _sessions[sessionId];
    if (session == null) {
      throw StateError('Unknown sessionId: $sessionId');
    }
    final clientHasSampling = session.capabilities?['sampling'] != null;
    if (!clientHasSampling) {
      throw McpError(
        'Client does not advertise the `sampling` capability',
        code: ErrorCode.methodNotFound,
      );
    }
    final result = await _sendRequestToClient(
        sessionId, 'sampling/createMessage', params, timeout: timeout);
    return result is Map<String, dynamic>
        ? result
        : Map<String, dynamic>.from(result as Map);
  }

  /// Server-initiated request: ask the connected client for its current
  /// list of filesystem / URI roots (spec `roots/list`).
  ///
  /// Client must advertise the `roots` capability.
  Future<List<Root>> requestClientRoots(
    String sessionId, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final session = _sessions[sessionId];
    if (session == null) {
      throw StateError('Unknown sessionId: $sessionId');
    }
    final clientHasRoots = session.capabilities?['roots'] != null;
    if (!clientHasRoots) {
      throw McpError(
        'Client does not advertise the `roots` capability',
        code: ErrorCode.methodNotFound,
      );
    }
    final result = await _sendRequestToClient(
        sessionId, 'roots/list', const {}, timeout: timeout);
    final list = result is Map ? (result['roots'] as List?) ?? const [] : const [];
    return list
        .map((e) => Root(
              uri: (e as Map)['uri'] as String,
              name: e['name'] as String? ?? '',
              description: e['description'] as String?,
            ))
        .toList();
  }

  /// Server-initiated request: ask the connected client to elicit input
  /// from the user (spec 2025-06-18 `elicitation/create`).
  ///
  /// [params] follows the spec `ElicitRequest.params` shape:
  /// `message` (string) + `requestedSchema` (restricted JSON Schema —
  /// flat object, primitive properties only).
  ///
  /// Returns the spec `ElicitResult` map: `action` (`accept` /
  /// `decline` / `cancel`) plus `content` when accepted.
  ///
  /// Client must advertise the `elicitation` capability.
  Future<Map<String, dynamic>> requestClientElicitation(
    String sessionId,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final session = _sessions[sessionId];
    if (session == null) {
      throw StateError('Unknown sessionId: $sessionId');
    }
    final clientHasElicitation = session.capabilities?['elicitation'] != null;
    if (!clientHasElicitation) {
      throw McpError(
        'Client does not advertise the `elicitation` capability',
        code: ErrorCode.methodNotFound,
      );
    }
    final result = await _sendRequestToClient(
        sessionId, 'elicitation/create', params, timeout: timeout);
    return result is Map<String, dynamic>
        ? result
        : Map<String, dynamic>.from(result as Map);
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

  /// Send a JSON-RPC response to specific session.
  void _sendResponse(String sessionId, dynamic id, dynamic result) {
    final session = _sessions[sessionId];
    if (session == null) {
      _logger.error('Attempted to send response to non-existent session: $sessionId');
      return;
    }

    final response = {
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    };
    session.transport.send(response);
  }

  /// Send a JSON-RPC error response to specific session.
  void _sendErrorResponse(String sessionId, dynamic id, int code, String message,
      [Map<String, dynamic>? data]) {
    final session = _sessions[sessionId];
    if (session == null) {
      _logger.error('Attempted to send error to non-existent session: $sessionId');
      return;
    }

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

    try {
      session.transport.send(response);
    } catch (e) {
      _logger.error('Failed to send error response: $e');
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
      '_targetSessionId': sessionId,  // Add target session ID for multi-session transports
    };

    session.transport.send(notification);
  }

  /// Send a server-initiated JSON-RPC request to a specific client and
  /// await the matching response.
  ///
  /// Used for spec-defined server → client requests:
  ///   - `sampling/createMessage`
  ///   - `roots/list`
  ///   - `elicitation/create`
  ///
  /// Throws [TimeoutException] if no response within [timeout] (default
  /// 60s). Throws [McpError] if the client returns a JSON-RPC error.
  Future<dynamic> _sendRequestToClient(
    String sessionId,
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 60),
  }) {
    final session = _sessions[sessionId];
    if (session == null) {
      throw StateError('Unknown sessionId for outbound request: $sessionId');
    }
    final id = 'srv-${++_outboundRequestSeq}';
    final completer = Completer<dynamic>();
    _pendingOutboundRequests[id] = completer;

    final message = {
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
      '_targetSessionId': sessionId,
    };
    session.transport.send(message);

    return completer.future.timeout(timeout, onTimeout: () {
      _pendingOutboundRequests.remove(id);
      throw TimeoutException(
          'Outbound request `$method` timed out after ${timeout.inSeconds}s');
    });
  }

  /// Match an incoming JSON-RPC response (`id` set, no `method`) to a
  /// pending outbound request and complete its Completer.
  void _handleOutboundResponse(JsonRpcMessage response) {
    final id = response.id?.toString();
    if (id == null) {
      _logger.warning('Received response without id; dropping.');
      return;
    }
    final completer = _pendingOutboundRequests.remove(id);
    if (completer == null) {
      _logger.warning(
          'Received response for unknown outbound request id `$id`; dropping.');
      return;
    }
    if (response.error != null) {
      completer.completeError(McpError(
        response.error!['message']?.toString() ?? 'Outbound request failed',
        code: response.error!['code'] is int
            ? response.error!['code'] as int
            : ErrorCode.internalError,
      ));
    } else {
      completer.complete(response.result);
    }
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
  
  /// Add a server-side root entry to the local cache.
  ///
  /// NOTE: Per MCP spec, roots are a client-owned concept — the server
  /// asks the client for its roots via [requestClientRoots]. This method
  /// only manages an OPTIONAL server-side cache and does NOT emit
  /// `notifications/roots/list_changed` (which would be in the wrong
  /// direction — spec defines that notification as client → server).
  /// Use [requestClientRoots] to fetch the client's authoritative roots.
  void addRoot(Root root) {
    if (_roots.any((r) => r.uri == root.uri)) {
      throw McpError('Root with URI "${root.uri}" already exists');
    }
    _roots.add(root);
  }

  /// Remove a server-side cached root entry (see [addRoot] for the
  /// direction caveat).
  void removeRoot(String uri) {
    if (!_roots.any((r) => r.uri == uri)) {
      throw McpError('Root with URI "$uri" does not exist');
    }
    _roots.removeWhere((r) => r.uri == uri);
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
  final int? code;
  final dynamic data;

  McpError(this.message, {this.code, this.data});

  @override
  String toString() =>
      code != null ? 'McpError($code): $message' : 'McpError: $message';
}

/// Internal: backing record for [Server.protectedResourceMetadata].
/// Spec: RFC 9728 OAuth 2.0 Protected Resource Metadata.
class _ProtectedResourceMetadata {
  final String resource;
  final List<String> authorizationServers;
  final List<String>? scopesSupported;
  final List<String>? bearerMethodsSupported;
  final String? resourceDocumentation;

  const _ProtectedResourceMetadata({
    required this.resource,
    required this.authorizationServers,
    this.scopesSupported,
    this.bearerMethodsSupported,
    this.resourceDocumentation,
  });
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

  /// Spec 2025-06-18 (RFC 9728): metadata for the server as an OAuth 2.0
  /// Protected Resource. Streamable HTTP transports SHOULD expose this at
  /// `/.well-known/oauth-protected-resource`. Returns `null` when
  /// authentication is not enabled.
  ///
  /// Set the source-of-truth fields via [configureProtectedResource].
  /// The metadata at minimum names the resource and the authorization
  /// servers that issue tokens for it. RFC 8707 (Resource Indicators)
  /// requires clients to send `resource: <this resource URI>` when
  /// requesting tokens, so the resource URI is mandatory.
  Map<String, dynamic>? get protectedResourceMetadata {
    if (_authMiddleware == null || _protectedResource == null) return null;
    final m = _protectedResource!;
    return <String, dynamic>{
      'resource': m.resource,
      'authorization_servers': m.authorizationServers,
      if (m.scopesSupported != null) 'scopes_supported': m.scopesSupported,
      if (m.bearerMethodsSupported != null)
        'bearer_methods_supported': m.bearerMethodsSupported,
      if (m.resourceDocumentation != null)
        'resource_documentation': m.resourceDocumentation,
    };
  }

  /// Configure the OAuth Protected Resource metadata served at
  /// `/.well-known/oauth-protected-resource` (RFC 9728).
  ///
  /// [resource] is the canonical resource URI clients pass as the
  /// `resource` parameter (RFC 8707) when requesting tokens.
  /// [authorizationServers] lists the AS issuer URLs that mint tokens
  /// valid for this resource. 2025-11-25 also recognises OIDC
  /// `.well-known/openid-configuration` discovery on those AS issuers.
  void configureProtectedResource({
    required String resource,
    required List<String> authorizationServers,
    List<String>? scopesSupported,
    List<String>? bearerMethodsSupported,
    String? resourceDocumentation,
  }) {
    _protectedResource = _ProtectedResourceMetadata(
      resource: resource,
      authorizationServers: List.unmodifiable(authorizationServers),
      scopesSupported: scopesSupported == null
          ? null
          : List.unmodifiable(scopesSupported),
      bearerMethodsSupported: bearerMethodsSupported == null
          ? null
          : List.unmodifiable(bearerMethodsSupported),
      resourceDocumentation: resourceDocumentation,
    );
  }
  
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
  

  /// Handle logging/setLevel request
  Future<void> _handleLoggingSetLevel(String sessionId, JsonRpcMessage request) async {
    // Validate capabilities
    if (capabilities.logging == null) {
      _sendErrorResponse(
        sessionId,
        request.id,
        ErrorCode.methodNotFound,
        'Logging capability not supported',
      );
      return;
    }

    // Get the requested log level
    final level = request.params?['level'] as String?;
    if (level == null) {
      _sendErrorResponse(
        sessionId,
        request.id,
        ErrorCode.invalidParams,
        'level parameter is required',
      );
      return;
    }

    // Validate log level
    final validLevels = ['debug', 'info', 'warning', 'error'];
    if (!validLevels.contains(level.toLowerCase())) {
      _sendErrorResponse(
        sessionId,
        request.id,
        ErrorCode.invalidParams,
        'Invalid log level. Valid levels are: ${validLevels.join(", ")}',
      );
      return;
    }

    // Update log level for the session
    final session = _sessions[sessionId];
    if (session != null) {
      session.logLevel = level.toLowerCase();
      _logger.info('Log level set to $level for session $sessionId');
    }

    // Send success response
    _sendResponse(sessionId, request.id, {});
  }

  /// Handle ping request
  Future<void> _handlePing(String sessionId, JsonRpcMessage request) async {
    // Simple ping/pong implementation for keepalive
    _sendResponse(sessionId, request.id, {
      'pong': true,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

}