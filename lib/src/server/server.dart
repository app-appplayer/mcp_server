import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:uuid/uuid.dart';

import '../../logger.dart';
import '../models/models.dart';
import '../transport/transport.dart';

final Logger _logger = Logger.getLogger('mcp_server.server');

/// Callback type for tool execution progress updates
typedef ProgressCallback = void Function(double progress, String message);

/// Callback type for checking if operation is cancelled
typedef IsCancelledCheck = bool Function();

/// Type definition for tool handler functions with cancellation and progress reporting
typedef ToolHandler = Future<CallToolResult> Function(Map<String, dynamic> arguments);

/// Type definition for resource handler functions
typedef ResourceHandler = Future<ReadResourceResult> Function(String uri, Map<String, dynamic> params);

/// Type definition for prompt handler functions
typedef PromptHandler = Future<GetPromptResult> Function(Map<String, dynamic> arguments);

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
  final List<String> supportedProtocolVersions = ["2024-11-05", "2025-03-26"];

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

  /// Server start time for health metrics
  final DateTime _startTime = DateTime.now();

  /// Metrics for performance monitoring
  final Map<String, int> _metricCounters = {};
  final Map<String, Stopwatch> _metricTimers = {};

  /// Stream controller for handling incoming messages
  final _messageController = StreamController<JsonRpcMessage>.broadcast();

  /// Whether the server is currently connected
  bool get isConnected => _transport != null;

  /// Creates a new MCP server with the specified parameters
  Server({
    required this.name,
    required this.version,
    this.capabilities = const ServerCapabilities(),
  });

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
      transport: transport,
      capabilities: {},
    );

    _sessions[sessionId] = session;
    _logger.debug('Created session: $sessionId');

    return sessionId;
  }

  /// Remove a client session
  void _removeSession(String sessionId) {
    _sessions.remove(sessionId);
    _logger.debug('Removed session: $sessionId');

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
          progress,
          message
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
    if (isConnected && capabilities.tools && capabilities.toolsListChanged) {
      _broadcastNotification('tools/listChanged', {});
    }
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
    if (isConnected && capabilities.resources && capabilities.resourcesListChanged) {
      _broadcastNotification('resources/listChanged', {});
    }
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
    if (isConnected && capabilities.prompts && capabilities.promptsListChanged) {
      _broadcastNotification('prompts/listChanged', {});
    }
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
    if (isConnected && capabilities.tools && capabilities.toolsListChanged) {
      _broadcastNotification('tools/listChanged', {});
    }
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
    if (isConnected && capabilities.resources && capabilities.resourcesListChanged) {
      _broadcastNotification('resources/listChanged', {});
    }
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
    if (isConnected && capabilities.prompts && capabilities.promptsListChanged) {
      _broadcastNotification('prompts/listChanged', {});
    }
  }

  /// Send a logging notification to the client
  void sendLog(McpLogLevel level, String message, {String? logger, Map<String, dynamic>? data}) {
    if (!isConnected) return;

    final params = {
      'level': level.index,
      'message': message,
    };

    if (logger != null) {
      params['logger'] = logger;
    }

    if (data != null) {
      params['data'] = data;
    }

    _broadcastNotification('logging', params);
  }

  /// Send progress notification to the client
  void sendProgressNotification(String sessionId, String requestId, double progress, String message) {
    if (!isConnected) return;

    final params = {
      'request_id': requestId,
      'progress': max(0.0, min(1.0, progress)), // Ensure progress is between 0 and 1
      'message': message,
    };

    _sendNotification(sessionId, 'progress', params);
  }

  /// Notify clients about a resource update
  void notifyResourceUpdated(String uri, ResourceContent content) {
    // Invalidate cache
    _resourceCache.remove(uri);

    if (!isConnected || !capabilities.resources) return;

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
      session.roots = roots;
      _logger.debug('Stored ${roots.length} client roots for session $sessionId');
    }
  }

  /// Check if a path is within client roots
  bool isPathWithinRoots(String sessionId, String path) {
    final session = _sessions[sessionId];
    if (session == null) return false;

    if (session.roots.isEmpty) return true; // No roots defined means all paths allowed

    for (final root in session.roots) {
      if (path.startsWith(root.uri)) {
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

  /// Handle incoming messages from the transport
  void _handleMessage(String sessionId, dynamic rawMessage) {
    try {
      final message = JsonRpcMessage.fromJson(
        rawMessage is String ? jsonDecode(rawMessage) : rawMessage,
      );
      message.sessionId = sessionId; // Attach session ID
      _messageController.add(message);
    } catch (e) {
      _logger.error('Parse error: $e');
      _sendErrorResponse(sessionId, null, ErrorCode.parseError, 'Parse error: $e');
    }
  }

  /// Process a JSON-RPC message
  Future<void> _processMessage(String sessionId, JsonRpcMessage message) async {
    final timerName = 'message.${message.isRequest ? "request" : "notification"}.${message.method}';
    startTimer(timerName);

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
        _sendErrorResponse(sessionId, message.id, ErrorCode.invalidRequest, 'Invalid request');
      }

      incrementMetric('messages.success');
    } catch (e, stackTrace) {
      incrementMetric('messages.errors');
      _logger.error('Error processing message: $e');
      _logger.debug('Stacktrace: $stackTrace');

      _sendErrorResponse(
          sessionId,
          message.id,
          ErrorCode.internalError,
          'Internal server error: ${e.toString()}'
      );
    } finally {
      stopTimer(timerName);
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
          'Session not initialized yet. Send initialize request first.'
      );
      return;
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
        await _handleResourcesList(sessionId, request);
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

      default:
        _sendErrorResponse(sessionId, request.id, ErrorCode.methodNotFound, 'Method not found');
    }
  }

  /// Handle initialize request
  Future<void> _handleInitialize(String sessionId, JsonRpcMessage request) async {
    // Handle protocol version negotiation
    final clientVersion = request.params?['protocolVersion'] as String?;
    String negotiatedVersion;

    if (clientVersion == null) {
      // Client didn't specify version, use latest
      negotiatedVersion = supportedProtocolVersions.last;
    } else if (supportedProtocolVersions.contains(clientVersion)) {
      // Client version is explicitly supported
      negotiatedVersion = clientVersion;
    } else {
      // Try to find a compatible version (date-based comparison)
      try {
        final clientDate = DateTime.parse(clientVersion);

        // Find supported versions that are equal or older than client version
        final compatibleVersions = supportedProtocolVersions
            .map((v) => DateTime.tryParse(v))
            .where((d) => d != null && d.compareTo(clientDate) <= 0)
            .cast<DateTime>()
            .toList();

        if (compatibleVersions.isNotEmpty) {
          // Sort in descending order and take newest compatible
          compatibleVersions.sort((a, b) => b.compareTo(a));
          final index = supportedProtocolVersions.indexWhere(
                  (v) => DateTime.tryParse(v)?.isAtSameMomentAs(compatibleVersions.first) ?? false);
          if (index >= 0) {
            negotiatedVersion = supportedProtocolVersions[index];
          } else {
            throw FormatException('No compatible version found');
          }
        } else {
          throw FormatException('No compatible version found');
        }
      } catch (e) {
        _sendErrorResponse(
            sessionId,
            request.id,
            ErrorCode.incompatibleVersion,
            'Unsupported protocol version: $clientVersion. Supported versions: ${supportedProtocolVersions.join(", ")}'
        );
        return;
      }
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

    if (!capabilities.tools) {
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
    if (!capabilities.tools) {
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
    if (!capabilities.resources) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.methodNotFound, 'Resources capability not supported');
      return;
    }

    final resourcesList = _resources.values.map((resource) => resource.toJson()).toList();

    _sendResponse(sessionId, request.id, {'resources': resourcesList});
  }

  /// Handle resources/read request
  Future<void> _handleResourceRead(String sessionId, JsonRpcMessage request) async {
    if (!capabilities.resources) {
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
    if (!capabilities.resources) {
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
    if (!capabilities.resources) {
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
    if (!capabilities.resources) {
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
    if (!capabilities.prompts) {
      _sendErrorResponse(sessionId, request.id, ErrorCode.methodNotFound, 'Prompts capability not supported');
      return;
    }

    final promptsList = _prompts.values.map((prompt) => prompt.toJson()).toList();
    _sendResponse(sessionId, request.id, {'prompts': promptsList});
  }

  /// Handle prompts/get request
  Future<void> _handlePromptGet(String sessionId, JsonRpcMessage request) async {
    if (!capabilities.prompts) {
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
    if (!capabilities.sampling) {
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
    final clientHasSampling = (clientCapabilities['sampling'] != null);
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

  /// Send a JSON-RPC error response to specific session
  void _sendErrorResponse(String sessionId, dynamic id, int code, String message, [Map<String, dynamic>? data]) {
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

    try {
      session.transport.send(response);
    } catch (e) {
      _logger.error('Failed to send error response: $e');
      // Instead of crashing, just log the error
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
}

/// Server capabilities configuration
class ServerCapabilities {
  /// Tool support
  final bool tools;

  /// Whether tools list changes are sent as notifications
  final bool toolsListChanged;

  /// Resource support
  final bool resources;

  /// Whether resources list changes are sent as notifications
  final bool resourcesListChanged;

  /// Prompt support
  final bool prompts;

  /// Whether prompts list changes are sent as notifications
  final bool promptsListChanged;

  /// Sampling support
  final bool sampling;

  /// Create a capabilities object with specified settings
  const ServerCapabilities({
    this.tools = false,
    this.toolsListChanged = false,
    this.resources = false,
    this.resourcesListChanged = false,
    this.prompts = false,
    this.promptsListChanged = false,
    this.sampling = false,
  });

  /// Convert capabilities to JSON
  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{};

    if (tools) {
      result['tools'] = {'listChanged': toolsListChanged};
    }

    if (resources) {
      result['resources'] = {'listChanged': resourcesListChanged};
    }

    if (prompts) {
      result['prompts'] = {'listChanged': promptsListChanged};
    }

    if (sampling) {
      result['sampling'] = {};
    }

    return result;
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