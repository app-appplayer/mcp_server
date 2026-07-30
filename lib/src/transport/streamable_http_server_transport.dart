/// MCP 2025-03-26 StreamableHTTP Server Transport Implementation
/// Fully compliant with MCP standard specification
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../../logger.dart';
import '../protocol/protocol.dart';
import '../protocol/request_meta.dart';
import 'transport.dart';

final Logger _logger = Logger('mcp_server.streamable_http_server_transport');

/// HTTP header carrying the MCP protocol version (2025-06-18+, and the sole
/// version signal on the 2026-07-28 stateless path).
const String mcpProtocolVersionHeader = 'mcp-protocol-version';

/// JSON-RPC error code: request `_meta.protocolVersion` disagrees with the
/// `MCP-Protocol-Version` header (2026-07-28 `HeaderMismatchError`).
const int _headerMismatch = -32020;

/// The client did not declare a capability the request needs (2026-07-28).
const int _missingRequiredClientCapability = -32021;

/// The requested protocol revision is not implemented here (2026-07-28).
/// The error carries the versions this server does support so the client can
/// retry rather than guess.
const int _unsupportedProtocolVersion = -32022;

/// Decodes the `=?base64?...?=` sentinel the spec defines for header values
/// that cannot be carried as plain ASCII. Returns the value unchanged when it
/// is not encoded, or null when the header is absent.
String? _decodeHeaderSentinel(String? raw) {
  if (raw == null) return null;
  if (!raw.startsWith('=?base64?') || !raw.endsWith('?=')) return raw;
  final payload = raw.substring('=?base64?'.length, raw.length - 2);
  try {
    return utf8.decode(base64.decode(payload));
  } catch (_) {
    return null;
  }
}

/// Standard request headers this revision requires. `Mcp-Name` is required
/// only for the operations that name a target.
const String _mcpMethodHeader = 'mcp-method';
const String _mcpNameHeader = 'mcp-name';
const Set<String> _methodsRequiringName = {
  'tools/call',
  'resources/read',
  'prompts/get',
};

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
  
  /// Authentication token for Bearer token validation (optional)
  final String? authToken;

  /// Enable GET stream for out-of-band server-initiated messages (per MCP 2025-03-26)
  /// When false, server returns 405 Method Not Allowed for GET requests
  final bool enableGetStream;

  /// Allowed `Origin` header values for DNS-rebinding protection
  /// (MCP 2025-11-25 requires HTTP 403 Forbidden for invalid `Origin`
  /// headers on the Streamable HTTP transport).
  ///
  /// A request carrying an `Origin` that is not in this list is rejected with
  /// `403 Forbidden` before dispatch. Requests without an `Origin` header are
  /// not affected — they did not come from a browser, so they cannot be a
  /// rebinding attempt.
  ///
  /// When null (default) the allow-list is the local machine
  /// (`localhost` / `127.0.0.1` / `[::1]`, any scheme or port). Name the
  /// origins that must reach this server to widen it, or set
  /// [allowAnyOrigin] to turn the check off.
  final List<String>? allowedOrigins;

  /// Space-delimited OAuth scope advertised on the `WWW-Authenticate`
  /// challenge emitted with a `401 Unauthorized` (MCP 2025-11-25 incremental
  /// scope consent / step-up, SEP-835). When non-null AND OAuth Protected
  /// Resource metadata is configured (`Server.configureProtectedResource`),
  /// the challenge carries `scope="<value>"` so the client knows which scopes
  /// to request when (re-)authorizing. Omitted (per spec) when null — the
  /// required scope is then "unknown" and not advertised. Backward compatible:
  /// no effect unless PRM is configured and a 401 is emitted.
  final String? challengeScope;

  /// Disables `Origin` checking entirely.
  ///
  /// The specification requires servers to validate `Origin` to prevent DNS
  /// rebinding, so this is not a knob to reach for; it exists for deployments
  /// that terminate the check in front of the server. Default **false**.
  final bool allowAnyOrigin;

  /// Opt-in for the 2026-07-28 stateless core (SEP-2577). Default **false**:
  /// 2026-07-28 is neither served nor advertised, and a request carrying
  /// `MCP-Protocol-Version: 2026-07-28` is rejected with an
  /// `UnsupportedProtocolVersionError` (JSON-RPC `-32022`, HTTP 400) — so
  /// there is ZERO behavior change from prior deployments.
  ///
  /// When true, a POST carrying `MCP-Protocol-Version: 2026-07-28` AND no
  /// `Mcp-Session-Id` is routed down the stateless branch: no session is
  /// created, client info/caps are read from the per-request `_meta`, and
  /// `server/discover` is served. Legacy handshake requests (and any request
  /// that carries a session id) keep the existing path unchanged, so one
  /// endpoint answers both revisions (matches the spec's own SDK approach:
  /// Go `StreamableHTTPOptions.Stateless`, Python "answers both revisions").
  final bool enableStateless;

  /// Revisions the stateless branch accepts. A request naming anything else is
  /// answered with the supported list so the client can retry.
  final Set<String> supportedProtocolVersions;

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
    this.authToken, // Optional Bearer token for authentication
    this.enableGetStream = true, // Default: enabled per MCP 2025-03-26
    this.allowedOrigins, // Optional DNS-rebinding protection (opt-in)
    this.challengeScope, // Optional WWW-Authenticate scope (SEP-835)
    this.allowAnyOrigin = false,
    this.enableStateless = false, // Opt-in 2026-07-28 stateless core (dormant)
    this.supportedProtocolVersions = const {McpProtocol.v2026_07_28},
  });
}

/// CORS configuration
@immutable
class CorsConfig {
  final String allowOrigin;
  final String allowMethods;
  final String allowHeaders;

  /// Response headers a browser is allowed to read.
  ///
  /// Without this a browser hides every non-simple response header, including
  /// `mcp-session-id` — the client would negotiate a session it can never see
  /// and every subsequent request would arrive unsessioned.
  final String exposeHeaders;

  final int maxAge;

  const CorsConfig({
    this.allowOrigin = '*',
    this.allowMethods = 'POST, OPTIONS, GET, DELETE',
    // `MCP-Protocol-Version` is sent by spec-conformant clients from
    // 2025-11-25 on. Omitting it fails the preflight, so a browser client
    // cannot reach this server at all.
    this.allowHeaders =
        'Content-Type, Authorization, Accept, X-Session-ID, mcp-session-id, '
        'last-event-id, MCP-Protocol-Version',
    this.exposeHeaders = 'mcp-session-id, MCP-Protocol-Version, WWW-Authenticate',
    this.maxAge = 86400,
  });
}

/// Event message with optional ID for SSE.
///
/// [forGetStream] marks events that were delivered on a session's standalone
/// GET SSE stream (server-initiated notifications / broadcasts) — these are
/// the events eligible for replay when a client reconnects the GET stream
/// with a `Last-Event-ID`. Per-request POST responses are stored too (for
/// event-id continuity) but are not replayed on a GET reconnect.
/// [targetSessionId] is null for broadcast events.
class EventMessage {
  final Map<String, dynamic> message;
  final String? eventId;
  final bool forGetStream;
  final String? targetSessionId;

  EventMessage({
    required this.message,
    this.eventId,
    this.forGetStream = false,
    this.targetSessionId,
  });
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

  // Session management - support multiple concurrent sessions
  final Map<String, StreamController<dynamic>> _sessionMessageControllers = {};
  final Set<String> _activeSessions = {};
  final Set<String> _terminatedSessions = {};
  
  // In-flight request tracking.
  //
  // Every map below is keyed by [_inflightKey] — `'<sessionId>:<requestId>'` —
  // NOT by the bare JSON-RPC id. JSON-RPC 2.0 only guarantees id uniqueness
  // *within* a session; clients routinely count from 1 per connection, so two
  // concurrent sessions collide on the bare id. With a bare key the second
  // registration silently overwrites the first, orphaning its HttpResponse
  // (the caller then hangs with 0 bytes until its own timeout) and delivering
  // the response to the wrong session.
  //
  // The session half of the key comes from `_sessionId` on the way in (every
  // inbound handler has it in scope) and from `_targetSessionId` on the way
  // out (stamped by `Server._sendResponse` / `_sendErrorResponse`).

  // Request tracking for JSON responses
  final Map<String, _PendingRequest> _pendingRequests = {};

  // Completers for synchronous JSON mode
  final Map<String, Completer<Map<String, dynamic>>> _pendingCompleters = {};

  // Completers for one-shot 2026-07-28 stateless requests. Kept separate from
  // `_pendingCompleters` so the stateless response path is independent of the
  // JSON/SSE response-mode config — a stateless request always resolves here
  // regardless of `isJsonResponseEnabled`. Dormant unless `enableStateless`.
  final Map<String, Completer<Map<String, dynamic>>> _statelessCompleters = {};

  // Completers for JSON-RPC batch entries (2024-11-05 / 2025-03-26; batching
  // was removed in 2025-06-18). Kept separate from `_pendingCompleters` so a
  // batched request resolves here regardless of `isJsonResponseEnabled` — the
  // whole batch is answered as one JSON array (spec-compliant). Empty unless a
  // batch is in flight.
  final Map<String, Completer<Map<String, dynamic>>> _batchCompleters = {};

  // Resolves a session's negotiated protocol revision, injected by
  // `Server.connect`. Lets the transport version-gate JSON-RPC batching (a
  // transport concern, since assembling the array response lives here) using
  // the same source of truth the server dispatch uses. Null until wired.
  String? Function(String sessionId)? _negotiatedVersionResolver;

  /// Injected by [Server] on `connect` so the transport can version-gate
  /// JSON-RPC batching on the session's negotiated protocol revision.
  void setNegotiatedVersionResolver(String? Function(String sessionId) r) {
    _negotiatedVersionResolver = r;
  }

  // Long-lived SSE streams for 2026-07-28 stateless `subscriptions/listen`
  // (SEP-2577), keyed by the listen request's JSON-RPC id (== the
  // subscriptionId). Notifications carrying `_meta.subscriptionId` and the
  // terminal `SubscriptionsListenResult` (response id == subscriptionId) are
  // routed here by `send()`. Dormant unless `enableStateless`.
  final Map<String, StreamController<String>> _statelessSubscriptionStreams =
      {};

  // Response store for asynchronous JSON mode
  final Map<String, Map<String, dynamic>> _responseStore = {};
  final Map<String, DateTime> _responseTimestamps = {};
  
  // SSE streams per in-flight request for streaming responses
  final Map<String, SseStreamInfo> _sseStreams = {};

  // Message router for proper request/response matching
  final Map<String, StreamController<dynamic>> _messageRouters = {};

  // GET streams per session for server-initiated messages (standalone SSE stream)
  final Map<String, SseStreamInfo> _getStreams = {};
  
  // Queue for responses waiting for GET stream in JSON mode
  final List<EventMessage> _pendingResponseQueue = [];
  
  // Event ID counter for resumability
  int _eventIdCounter = 0;
  
  // Event store for resumability (simplified implementation)
  final Map<String, EventMessage> _eventStore = {};
  
  // Timer for cleanup of old responses
  Timer? _cleanupTimer;

  // RFC 9728 OAuth Protected Resource metadata provider. Server.connect()
  // wires this so the transport can serve the spec-defined
  // `.well-known/oauth-protected-resource` route without the transport
  // needing a back-reference to the Server.
  Map<String, dynamic>? Function()? _protectedResourceMetadataProvider;

  /// Register a callback the transport will invoke to populate the
  /// `.well-known/oauth-protected-resource` document. Returning `null`
  /// from the callback causes the route to respond with 404.
  void setProtectedResourceMetadataProvider(
      Map<String, dynamic>? Function() provider) {
    _protectedResourceMetadataProvider = provider;
  }

  StreamableHttpServerTransport({
    required this.config,
    @Deprecated('sessionId parameter is ignored. StreamableHTTP now manages multiple sessions internally.')
    String? sessionId,
  }) {
    // Note: sessionId parameter is ignored for backward compatibility
    // StreamableHTTP now supports multiple concurrent sessions

    // Start cleanup timer for async mode
    if (config.isJsonResponseEnabled && config.jsonResponseMode == 'async') {
      _cleanupTimer = Timer.periodic(Duration(minutes: 1), (_) => _cleanupOldResponses());
    }
  }

  /// Get session ID - deprecated
  /// Returns empty string as this transport now manages multiple sessions
  @Deprecated('StreamableHTTP now manages multiple sessions internally. This getter returns empty string.')
  String get sessionId => '';

  static String _generateSessionId() {
    return const Uuid().v4();
  }

  /// Composite key for every in-flight request map.
  ///
  /// A JSON-RPC id is unique only within its own session, so the session id is
  /// the other half of the identity. The wire id itself is never rewritten —
  /// the client always gets its own id back, and `notifications/cancelled`
  /// (which references the client's original id) keeps matching.
  static String _inflightKey(String sessionId, dynamic requestId) =>
      '$sessionId:$requestId';

  /// Extract or generate session ID from request
  String _getOrCreateSessionId(HttpRequest request) {
    var sessionId = request.headers.value(mcpSessionIdHeader);

    // Validate session ID from client
    if (sessionId != null && sessionId.isNotEmpty) {
      // Reject any request that quotes a session id we've already
      // terminated (DELETE marked it). Returning the same id (without
      // adding it to _activeSessions) lets the caller's later
      // `_isSessionTerminated(sessionId)` check fire and reply 404.
      // Without this branch, the else-clause below silently rotated
      // the terminated id into a fresh active id, defeating
      // session-termination.
      if (_terminatedSessions.contains(sessionId)) {
        _logger.debug('Reusing terminated session id for rejection: '
            '$sessionId');
        return sessionId;
      }
      // Check if session is active (session reconnection)
      if (_activeSessions.contains(sessionId)) {
        _logger.debug('Session reconnected: $sessionId');
        return sessionId;
      } else {
        // Session ID from client is not valid (server may have restarted)
        // Generate new session ID and log the event
        _logger.info('⚠️  Invalid session ID from client: $sessionId (server restarted or session expired)');
        _logger.info('🔄 Generating new session ID for client');
        sessionId = _generateSessionId();
      }
    } else {
      // No session ID from client - first connection
      sessionId = _generateSessionId();
      _logger.debug('Generated new session ID: $sessionId');
    }

    // Track active session
    _activeSessions.add(sessionId);
    _logger.debug('New session registered: $sessionId');

    // Notify Server about new session via message controller
    if (!_messageController.isClosed && !_sessionMessageControllers.containsKey(sessionId)) {
      final sessionController = StreamController<dynamic>();
      _sessionMessageControllers[sessionId] = sessionController;
    }

    return sessionId;
  }

  /// Check if session is terminated
  bool _isSessionTerminated(String sessionId) {
    return _terminatedSessions.contains(sessionId);
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
      // Session termination is now checked per-session in _validateSession()

      // DNS-rebinding protection (MCP 2025-11-25): reject a request whose
      // `Origin` header is present but not allow-listed with 403 Forbidden,
      // before any dispatch. Opt-in — enforced only when `allowedOrigins`
      // is configured; requests without an `Origin` header are unaffected.
      if (!_isOriginAllowed(request)) {
        _setCorsHeaders(request.response);
        _sendErrorResponse(
          request.response,
          '',
          'Forbidden: Origin not allowed',
          HttpStatus.forbidden,
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

      // RFC 9728 OAuth Protected Resource metadata. Served unconditionally
      // when the Server has registered metadata via
      // `Server.configureProtectedResource(...)` — the route is read-only
      // and intentionally bypasses the Bearer-token check (clients query
      // it precisely to discover where to obtain a token).
      if (request.method == 'GET' &&
          requestPath == '/.well-known/oauth-protected-resource') {
        await _handleProtectedResourceMetadata(request);
        return;
      }

      if (requestPath != configEndpoint) {
        _sendErrorResponse(
          request.response,
          '',
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
            '',
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
          '',
          'Internal Server Error: ${e.toString()}',
          HttpStatus.internalServerError,
        );
      } catch (_) {
        // Response already sent
      }
    }
  }
  
  /// Handle GET `/.well-known/oauth-protected-resource` (RFC 9728).
  /// Returns the JSON metadata when the Server has called
  /// [Server.configureProtectedResource]; otherwise 404.
  Future<void> _handleProtectedResourceMetadata(HttpRequest request) async {
    _setCorsHeaders(request.response);
    final metadata = _protectedResourceMetadataProvider?.call();
    if (metadata == null) {
      _sendErrorResponse(
        request.response,
        '',
        'Not Found: Protected Resource metadata is not configured',
        HttpStatus.notFound,
      );
      return;
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.set('Content-Type', contentTypeJson);
    request.response.write(jsonEncode(metadata));
    await request.response.close();
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
    // Validate Bearer token first (if configured)
    if (!_validateBearerToken(request)) {
      return;
    }

    // 2026-07-28 stateless-core routing (SEP-2577). A POST carrying
    // `MCP-Protocol-Version: 2026-07-28` and NO `Mcp-Session-Id` is a
    // stateless request. Ambiguity guard: a request that ALSO carries a
    // session id is treated as legacy (session wins), so it falls through.
    final protoHeader = request.headers.value(mcpProtocolVersionHeader);
    final incomingSessionId = request.headers.value(mcpSessionIdHeader);
    final hasSessionId =
        incomingSessionId != null && incomingSessionId.isNotEmpty;
    // A version this build does not implement at all is answered with the
    // supported list. Falling through to the legacy path instead would return
    // a bare "invalid request", leaving the client nothing to retry with.
    if (protoHeader != null &&
        protoHeader.isNotEmpty &&
        protoHeader != McpProtocol.v2026_07_28 &&
        !McpProtocol.supportedVersions.contains(protoHeader)) {
      await _sendUnsupportedProtocolVersion(request.response, protoHeader);
      return;
    }

    if (protoHeader == McpProtocol.v2026_07_28 && !hasSessionId) {
      if (!config.enableStateless) {
        // Version gate: 2026-07-28 is not served when the flag is off — the
        // client should fall back to the `initialize` handshake.
        await _sendUnsupportedProtocolVersion(request.response, protoHeader!);
        return;
      }
      await _handleStatelessPostRequest(request);
      return;
    }

    // Extract or create session ID
    final sessionId = _getOrCreateSessionId(request);

    // Check if session is terminated
    if (_isSessionTerminated(sessionId)) {
      _sendErrorResponse(
        request.response,
        sessionId,
        'Not Found: Session has been terminated',
        HttpStatus.notFound,
      );
      return;
    }

    // Validate headers according to MCP StreamableHTTP specification
    if (!_validateAcceptHeaders(request)) {
      _sendErrorResponse(
        request.response,
        sessionId,
        'Not Acceptable: Client must accept both application/json and text/event-stream',
        HttpStatus.notAcceptable,
      );
      return;
    }

    if (!_validateContentType(request)) {
      _sendErrorResponse(
        request.response,
        sessionId,
        'Unsupported Media Type: Content-Type must be application/json',
        HttpStatus.unsupportedMediaType,
      );
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
        sessionId,
        'Request Too Large',
        HttpStatus.requestEntityTooLarge,
      );
      return;
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (e) {
      _sendJsonRpcError(
        request.response,
        sessionId,
        null,
        -32700,
        'Parse error',
        'Invalid JSON: $e',
      );
      return;
    }

    // JSON-RPC batching (a JSON array of messages) is valid only on
    // 2024-11-05 / 2025-03-26 (removed in 2025-06-18). Assembling the batched
    // array response is a transport concern, so it is handled here rather than
    // in `Server._handleMessage` (which owns the batch path for stdio).
    if (decoded is List) {
      await _handleBatchRequest(request, decoded, sessionId);
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      _sendJsonRpcError(
        request.response,
        sessionId,
        null,
        -32600,
        'Invalid Request',
        'Not a valid JSON-RPC 2.0 request',
      );
      return;
    }
    final Map<String, dynamic> jsonRpcRequest = decoded;
    // Reserved transport control keys are set by the transport, never by the
    // client. Strip any forged ones so a request body cannot inject
    // `_stateless` (which would otherwise reach the server's stateless router)
    // or spoof `_sessionId` / `_protocolVersion`.
    _stripReservedKeys(jsonRpcRequest);

    // Validate JSON-RPC format
    if (!_isValidJsonRpc(jsonRpcRequest)) {
      _sendJsonRpcError(
        request.response,
        sessionId,
        null,
        -32600,
        'Invalid Request',
        'Not a valid JSON-RPC 2.0 request',
      );
      return;
    }

    // Wrap message with session ID metadata for Server
    final bearer = _bearerCredential(request);
    final wrappedMessage = {
      ...jsonRpcRequest,
      '_sessionId': sessionId,  // Internal metadata for session routing
      if (bearer != null) '_authorization': bearer,
    };

    // Handle notification (no response expected) AND incoming responses
    // to server-initiated requests (id present but no method, just
    // result/error). Both should be queued without making the caller
    // wait for an application-level response — the application either
    // ignores the notification or matches the response to a pending
    // outbound request via Server._handleOutboundResponse.
    final isResponse = jsonRpcRequest['method'] is! String &&
        jsonRpcRequest.containsKey('id') &&
        (jsonRpcRequest.containsKey('result') ||
            jsonRpcRequest['error'] is Map);
    if (jsonRpcRequest['id'] == null || isResponse) {
      // Send to message controller with session metadata
      if (!_messageController.isClosed) {
        _messageController.add(wrappedMessage);
      }

      // Return 202 Accepted for notifications and responses
      request.response.statusCode = HttpStatus.accepted;
      request.response.headers.set('Content-Type', contentTypeJson);
      request.response.headers.set('Content-Length', '0');
      request.response.headers.set(mcpSessionIdHeader, sessionId);
      await request.response.close();
      return;
    }

    // Handle request with ID based on mode
    if (config.isJsonResponseEnabled) {
      // JSON mode
      if (config.jsonResponseMode == 'sync') {
        // Synchronous JSON mode: wait for response and return directly
        await _handleSyncJsonResponse(request, wrappedMessage, sessionId);
      } else {
        // Asynchronous JSON mode: return 202 with polling location
        await _handleAsyncJsonResponse(request, wrappedMessage, sessionId);
      }
    } else {
      // SSE streaming mode (default for StreamableHTTP)
      await _handleSseResponse(request, wrappedMessage, sessionId);
    }
  }

  /// Handle a 2026-07-28 stateless-core POST (opt-in via `enableStateless`).
  ///
  /// No session is created or registered: the request rides its own client
  /// info/caps in `_meta`, and the response is a single JSON body (no SSE, no
  /// `Mcp-Session-Id`). The transient session id exists only to route the
  /// server's reply back through [send] via [_statelessCompleters].
  Future<void> _handleStatelessPostRequest(HttpRequest request) async {
    if (!_validateAcceptHeaders(request)) {
      await _sendUnroutedError(request.response, HttpStatus.notAcceptable,
          'Not Acceptable: Client must accept both application/json and text/event-stream');
      return;
    }
    if (!_validateContentType(request)) {
      await _sendUnroutedError(request.response, HttpStatus.unsupportedMediaType,
          'Unsupported Media Type: Content-Type must be application/json');
      return;
    }

    final body = await utf8.decoder
        .bind(request)
        .join()
        .timeout(config.requestTimeout);
    if (body.length > config.maxRequestSize) {
      await _sendUnroutedError(
          request.response, HttpStatus.requestEntityTooLarge, 'Request Too Large');
      return;
    }

    Map<String, dynamic> jsonRpcRequest;
    try {
      jsonRpcRequest = jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      _sendJsonRpcError(
          request.response, '', null, -32700, 'Parse error', 'Invalid JSON: $e');
      return;
    }
    // Strip client-forged reserved control keys; this path sets the legitimate
    // `_stateless` / `_protocolVersion` / `_sessionId` itself, from the route
    // and the `MCP-Protocol-Version` header.
    _stripReservedKeys(jsonRpcRequest);
    if (!_isValidJsonRpc(jsonRpcRequest)) {
      _sendJsonRpcError(request.response, '', null, -32600, 'Invalid Request',
          'Not a valid JSON-RPC 2.0 request');
      return;
    }

    final protoHeader = request.headers.value(mcpProtocolVersionHeader)!;

    // Schema: for HTTP the request `_meta.protocolVersion` MUST equal the
    // `MCP-Protocol-Version` header; otherwise 400 (HeaderMismatchError,
    // -32020). A stateless request also MUST declare `clientCapabilities`.
    final meta = (jsonRpcRequest['params'] is Map)
        ? (jsonRpcRequest['params'] as Map)['_meta']
        : null;
    final metaVersion = McpRequestMeta.readProtocolVersion(meta);
    final method = jsonRpcRequest['method'] as String?;

    // The revision must be one this server implements. Answering with a plain
    // "invalid request" would leave the client nothing to retry with, so the
    // supported list travels in the error.
    if (!config.supportedProtocolVersions.contains(protoHeader)) {
      _sendJsonRpcErrorStatus(
        request.response,
        jsonRpcRequest['id'],
        _unsupportedProtocolVersion,
        'Unsupported protocol version',
        HttpStatus.badRequest,
        data: {
          'supported': config.supportedProtocolVersions.toList(),
          'requested': protoHeader,
        },
      );
      return;
    }

    // Requests only. This revision defines no client-to-server notifications
    // over Streamable HTTP and explicitly leaves header requirements for
    // notification POSTs undefined, so the per-request obligations below must
    // not be imposed on one.
    final isNotification = jsonRpcRequest['id'] == null;

    // This revision carries version, identity and capabilities per request.
    // Accepting a request without them would mean inferring context from the
    // connection — exactly what the stateless core removes.
    if (!isNotification && metaVersion == null) {
      _sendJsonRpcErrorStatus(
        request.response,
        jsonRpcRequest['id'],
        -32602,
        'Invalid params',
        HttpStatus.badRequest,
        data: 'Missing required _meta.io.modelcontextprotocol/protocolVersion',
      );
      return;
    }
    if (!isNotification && McpRequestMeta.readClientCapabilities(meta) == null) {
      _sendJsonRpcErrorStatus(
        request.response,
        jsonRpcRequest['id'],
        _missingRequiredClientCapability,
        'Missing required client capability',
        HttpStatus.badRequest,
        data: {
          'requiredCapabilities': ['io.modelcontextprotocol/clientCapabilities'],
        },
      );
      return;
    }

    // Standard request headers mirror body fields so intermediaries can route
    // without parsing. A mirror that is absent, or disagrees with the body, is
    // rejected — the two must not be able to say different things.
    final methodHeader = request.headers.value(_mcpMethodHeader);
    if (!isNotification && (methodHeader == null || methodHeader != method)) {
      _sendJsonRpcErrorStatus(
        request.response,
        jsonRpcRequest['id'],
        _headerMismatch,
        'Header mismatch',
        HttpStatus.badRequest,
        data: methodHeader == null
            ? 'Missing required Mcp-Method header'
            : 'Mcp-Method ($methodHeader) does not match body method ($method)',
      );
      return;
    }
    if (!isNotification && _methodsRequiringName.contains(method)) {
      final params = jsonRpcRequest['params'];
      final bodyName = params is Map
          ? (params['name'] ?? params['uri']) as Object?
          : null;
      final nameHeader = request.headers.value(_mcpNameHeader);
      final decoded = _decodeHeaderSentinel(nameHeader);
      if (decoded == null || decoded != bodyName) {
        _sendJsonRpcErrorStatus(
          request.response,
          jsonRpcRequest['id'],
          _headerMismatch,
          'Header mismatch',
          HttpStatus.badRequest,
          data: decoded == null
              ? 'Missing required Mcp-Name header'
              : 'Mcp-Name ($decoded) does not match body value ($bodyName)',
        );
        return;
      }
    }

    if (!isNotification && metaVersion != protoHeader) {
      _sendJsonRpcErrorStatus(
        request.response,
        jsonRpcRequest['id'],
        _headerMismatch,
        'Header mismatch',
        HttpStatus.badRequest,
        data:
            'Request _meta.protocolVersion ($metaVersion) does not match MCP-Protocol-Version header ($protoHeader)',
      );
      return;
    }

    // A transient, unregistered session id — never added to `_activeSessions`.
    final ephemeralId = _generateSessionId();
    final bearer = _bearerCredential(request);
    final wrappedMessage = <String, dynamic>{
      ...jsonRpcRequest,
      '_sessionId': ephemeralId,
      '_stateless': true,
      '_protocolVersion': protoHeader,
      if (bearer != null) '_authorization': bearer,
    };

    // 2026-07-28 `subscriptions/listen` (SEP-2577): a long-lived SSE stream
    // replaces the old HTTP GET SSE endpoint. Open the stream keyed by the
    // request id (== subscriptionId) and let the server drive it (acknowledged
    // notification first, then filtered notifications, then the terminal
    // `SubscriptionsListenResult` on teardown/cancel).
    if (jsonRpcRequest['method'] == 'subscriptions/listen' &&
        jsonRpcRequest['id'] != null) {
      await _handleStatelessSubscribe(request, wrappedMessage);
      return;
    }

    // Notifications / responses on the stateless path: enqueue and 202.
    final id = jsonRpcRequest['id'];
    final isResponse = jsonRpcRequest['method'] is! String &&
        (jsonRpcRequest.containsKey('result') ||
            jsonRpcRequest['error'] is Map);
    if (id == null || isResponse) {
      if (!_messageController.isClosed) {
        _messageController.add(wrappedMessage);
      }
      request.response.statusCode = HttpStatus.accepted;
      request.response.headers.set('Content-Type', contentTypeJson);
      request.response.headers.set('Content-Length', '0');
      await request.response.close();
      return;
    }

    final completer = Completer<Map<String, dynamic>>();
    final inflightKey = _inflightKey(ephemeralId, id);
    _statelessCompleters[inflightKey] = completer;
    if (!_messageController.isClosed) {
      _messageController.add(wrappedMessage);
    }

    try {
      final response = await completer.future.timeout(
        config.requestTimeout,
        onTimeout: () => throw TimeoutException('Request timeout'),
      );
      request.response.statusCode = HttpStatus.ok;
      request.response.headers
          .set('Content-Type', 'application/json; charset=utf-8');
      // Echo the protocol version; deliberately NO `Mcp-Session-Id` (stateless).
      request.response.headers.set(mcpProtocolVersionHeader, protoHeader);
      // B1f (SEP-2577): propagate W3C Trace Context back to the caller when the
      // request carried it (additive; absent → no header).
      _propagateTraceContext(request, request.response);
      request.response.add(utf8.encode(json.encode(response)));
      await request.response.close();
    } on TimeoutException {
      _statelessCompleters.remove(inflightKey);
      _sendJsonRpcErrorStatus(request.response, id, -32603, 'Request timeout',
          HttpStatus.gatewayTimeout);
    }
  }

  /// B1f (SEP-2577): propagate W3C Trace Context (`traceparent`/`tracestate`/
  /// `baggage`) from an inbound stateless [request] onto its [response] when
  /// present. Additive and header-name-cased per the W3C spec; a request without
  /// trace context yields no headers.
  void _propagateTraceContext(HttpRequest request, HttpResponse response) {
    for (final h in const ['traceparent', 'tracestate', 'baggage']) {
      final v = request.headers.value(h);
      if (v != null && v.isNotEmpty) {
        response.headers.set(h, v);
      }
    }
  }

  /// Open the long-lived SSE stream for a 2026-07-28 `subscriptions/listen`
  /// request (SEP-2577). The stream is keyed by the request id (the
  /// subscriptionId). The server delivers the acknowledged notification,
  /// filtered stream notifications, and the terminal `SubscriptionsListenResult`
  /// through [send], which routes them here by `_meta.subscriptionId` (for
  /// notifications) or by response id. The stream stays open until the server
  /// closes it (graceful teardown / cancellation) or the client disconnects.
  Future<void> _handleStatelessSubscribe(
      HttpRequest request, Map<String, dynamic> wrappedMessage) async {
    final subscriptionId = wrappedMessage['id'];
    // Same collision axis as every other in-flight map: the subscriptionId is
    // the listen request's JSON-RPC id, unique only within its own session.
    final streamKey =
        _inflightKey(wrappedMessage['_sessionId'] as String, subscriptionId);

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.set('Content-Type', contentTypeSse);
    request.response.headers.set('Cache-Control', 'no-cache, no-transform');
    request.response.headers.set('Connection', 'keep-alive');
    // Stateless: deliberately NO `Mcp-Session-Id`; echo the protocol version.
    request.response.headers.set(
        mcpProtocolVersionHeader, wrappedMessage['_protocolVersion'] as String);
    _propagateTraceContext(request, request.response);
    // Disable output buffering so each SSE event is written to the socket
    // immediately (a long-lived stream must not wait for the buffer to fill).
    request.response.bufferOutput = false;

    final controller = StreamController<String>();
    _statelessSubscriptionStreams[streamKey] = controller;

    controller.stream.listen(
      (data) {
        request.response.add(utf8.encode(data));
        // Long-lived SSE: flush each event immediately so the client sees it
        // live (a buffered response would only surface events on close).
        unawaited(request.response.flush());
      },
      onDone: () async {
        try {
          await request.response.close();
        } catch (_) {}
        _statelessSubscriptionStreams.remove(streamKey);
      },
      onError: (_) => _statelessSubscriptionStreams.remove(streamKey),
    );

    // Clean up if the client disconnects before graceful teardown.
    unawaited(request.response.done.whenComplete(() {
      if (_statelessSubscriptionStreams.remove(streamKey) != null &&
          !controller.isClosed) {
        controller.close();
      }
    }));

    // Route into the server so it can register the subscription + acknowledge.
    if (!_messageController.isClosed) {
      _messageController.add(wrappedMessage);
    }
  }

  /// Emit an `UnsupportedProtocolVersionError` (-32022, HTTP 400) — the
  /// server does not support the requested protocol version.
  Future<void> _sendUnsupportedProtocolVersion(
      HttpResponse response, String requested) async {
    response.statusCode = HttpStatus.badRequest;
    response.headers.set('Content-Type', 'application/json; charset=utf-8');
    final payload = {
      'jsonrpc': '2.0',
      'id': null,
      'error': {
        'code': _unsupportedProtocolVersion,
        'message': 'Unsupported protocol version',
        'data': {
          'supported': McpProtocol.supportedVersions,
          'requested': requested,
        },
      },
    };
    response.add(utf8.encode(jsonEncode(payload)));
    await response.close();
  }

  /// Write a JSON-RPC error with a specific HTTP status code.
  void _sendJsonRpcErrorStatus(HttpResponse response, dynamic id, int code,
      String message, int status,
      {Object? data}) {
    response.statusCode = status;
    response.headers.set('Content-Type', 'application/json; charset=utf-8');
    final payload = {
      'jsonrpc': '2.0',
      if (id != null) 'id': id,
      'error': {
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      },
    };
    response.add(utf8.encode(jsonEncode(payload)));
    response.close();
  }

  /// Write a plain non-JSON-RPC HTTP error (used before a JSON-RPC id is
  /// known on the stateless path).
  Future<void> _sendUnroutedError(
      HttpResponse response, int status, String message) async {
    response.statusCode = status;
    response.headers.set('Content-Type', 'text/plain; charset=utf-8');
    response.write(message);
    await response.close();
  }

  /// Handle synchronous JSON response mode
  /// Handle a JSON-RPC batch POST (an array of messages).
  ///
  /// Batching is valid only for sessions that negotiated 2024-11-05 /
  /// 2025-03-26 (removed in 2025-06-18); otherwise it is rejected with -32600
  /// (a valid array that the negotiated revision forbids — not a parse error).
  /// Each entry is dispatched individually and the responses for entries that
  /// are *requests* are collected into a single JSON array. Notification-only
  /// batches get 202 Accepted. Independent of `isJsonResponseEnabled`.
  Future<void> _handleBatchRequest(
      HttpRequest request, List<dynamic> batch, String sessionId) async {
    final negotiated = _negotiatedVersionResolver?.call(sessionId);
    final allow = negotiated != null && McpProtocol.supportsBatching(negotiated);
    if (!allow) {
      _sendJsonRpcError(
        request.response,
        sessionId,
        null,
        -32600,
        'Invalid Request',
        'JSON-RPC batching is not supported on protocol '
            '${negotiated ?? 'unnegotiated'} (removed in 2025-06-18)',
      );
      return;
    }
    if (batch.isEmpty) {
      _sendJsonRpcError(request.response, sessionId, null, -32600,
          'Invalid Request', 'Empty JSON-RPC batch');
      return;
    }

    // Keys, not bare ids: a batch entry's id collides with a concurrent
    // session's just like a single request's does.
    final requestKeys = <String>[];
    for (final item in batch) {
      if (item is! Map<String, dynamic>) continue;
      _stripReservedKeys(item);
      final isRequest = item['method'] is String && item['id'] != null;
      if (isRequest) {
        final key = _inflightKey(sessionId, item['id']);
        _batchCompleters[key] = Completer<Map<String, dynamic>>();
        requestKeys.add(key);
      }
      if (!_messageController.isClosed) {
        final bearer = _bearerCredential(request);
        _messageController.add(<String, dynamic>{
          ...item,
          '_sessionId': sessionId,
          if (bearer != null) '_authorization': bearer,
        });
      }
    }

    // Notification-only batch: nothing to answer.
    if (requestKeys.isEmpty) {
      request.response.statusCode = HttpStatus.accepted;
      request.response.headers.set('Content-Type', contentTypeJson);
      request.response.headers.set('Content-Length', '0');
      request.response.headers.set(mcpSessionIdHeader, sessionId);
      await request.response.close();
      return;
    }

    try {
      final responses = <Map<String, dynamic>>[];
      for (final key in requestKeys) {
        responses.add(await _batchCompleters[key]!.future.timeout(
              config.requestTimeout,
              onTimeout: () => throw TimeoutException('Batch request timeout'),
            ));
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers
          .set('Content-Type', 'application/json; charset=utf-8');
      request.response.headers.set(mcpSessionIdHeader, sessionId);
      request.response.add(utf8.encode(json.encode(responses)));
      await request.response.close();
    } catch (e) {
      _sendJsonRpcError(request.response, sessionId, null, -32603,
          'Internal error', 'Batch processing error: $e');
    } finally {
      for (final key in requestKeys) {
        _batchCompleters.remove(key);
      }
    }
  }

  Future<void> _handleSyncJsonResponse(HttpRequest request, Map<String, dynamic> jsonRpcRequest, String sessionId) async {
    final requestId = jsonRpcRequest['id'];
    final inflightKey = _inflightKey(sessionId, requestId);

    // Create completer for this request
    final completer = Completer<Map<String, dynamic>>();
    _pendingCompleters[inflightKey] = completer;
    _logger.debug('Created completer for request $inflightKey (id type: ${requestId.runtimeType})');

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

      // Send direct JSON response
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set('Content-Type', 'application/json; charset=utf-8');
      request.response.headers.set(mcpSessionIdHeader, sessionId);
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
      _pendingCompleters.remove(inflightKey);
    }
  }

  /// Handle asynchronous JSON response mode with polling
  Future<void> _handleAsyncJsonResponse(HttpRequest request, Map<String, dynamic> jsonRpcRequest, String sessionId) async {
    final requestId = jsonRpcRequest['id'];
    // Same shape as the polling Location and `_responseStore` key.
    final responseKey = _inflightKey(sessionId, requestId);

    // Store pending request with sessionId
    _pendingRequests[responseKey] = _PendingRequest(
      request: request,
      timestamp: DateTime.now(),
      sessionId: sessionId,
    );

    // Send to message controller
    if (!_messageController.isClosed) {
      _messageController.add(jsonRpcRequest);
    }

    // Return 202 Accepted with Location header
    request.response.statusCode = HttpStatus.accepted;
    request.response.headers.set('Content-Type', contentTypeJson);
    request.response.headers.set(mcpSessionIdHeader, sessionId);
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

    // Extract sessionId from responseKey (format: "sessionId:requestId")
    final sessionId = responseKey.split(':').first;

    _setCorsHeaders(request.response);

    if (_responseStore.containsKey(responseKey)) {
      final response = _responseStore[responseKey]!;

      // Send the stored response
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set('Content-Type', 'application/json; charset=utf-8');
      request.response.headers.set(mcpSessionIdHeader, sessionId);
      request.response.add(utf8.encode(json.encode(response)));
      await request.response.close();

      // Clean up
      _responseStore.remove(responseKey);
      _responseTimestamps.remove(responseKey);
    } else {
      // Response not ready yet
      request.response.statusCode = HttpStatus.noContent;
      request.response.headers.set(mcpSessionIdHeader, sessionId);
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
  Future<void> _handleSseResponse(HttpRequest request, Map<String, dynamic> jsonRpcRequest, String sessionId) async {
    final requestId = jsonRpcRequest['id'];
    final inflightKey = _inflightKey(sessionId, requestId);

    // Set SSE headers
    request.response.headers.set('Content-Type', contentTypeSse);
    request.response.headers.set('Cache-Control', 'no-cache, no-transform');
    request.response.headers.set('Connection', 'keep-alive');
    request.response.headers.set(mcpSessionIdHeader, sessionId);

    // Create SSE stream for this request
    final sseController = StreamController<String>();
    _sseStreams[inflightKey] = SseStreamInfo(
      controller: sseController,
      response: request.response,
    );

    // Create message router for this request
    final messageRouter = StreamController<dynamic>();
    _messageRouters[inflightKey] = messageRouter;

    // Start sending SSE events with proper UTF-8 encoding
    sseController.stream.listen(
      (data) {
        request.response.add(utf8.encode(data));
      },
      onDone: () async {
        await request.response.close();
        _sseStreams.remove(inflightKey);
        _messageRouters.remove(inflightKey)?.close();
      },
      onError: (error) {
        _logger.error('SSE stream error: $error');
        _sseStreams.remove(inflightKey);
        _messageRouters.remove(inflightKey)?.close();
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

    // Check if GET stream is enabled per MCP 2025-03-26
    if (!config.enableGetStream) {
      _logger.debug('GET stream disabled - returning 405 Method Not Allowed');
      // For GET requests without session, use empty string as sessionId
      _sendErrorResponse(
        request.response,
        '',
        'Method Not Allowed: GET stream is disabled',
        HttpStatus.methodNotAllowed,
      );
      request.response.headers.set('Allow', 'POST, OPTIONS, DELETE');
      return;
    }

    // Validate Bearer token first (if configured)
    if (!_validateBearerToken(request)) {
      return;
    }

    // Extract or create session ID
    final sessionId = _getOrCreateSessionId(request);

    // Check if session is terminated
    if (_isSessionTerminated(sessionId)) {
      _sendErrorResponse(
        request.response,
        sessionId,
        'Not Found: Session has been terminated',
        HttpStatus.notFound,
      );
      return;
    }

    // Validate Accept header - more lenient for GET requests.
    // Use the list form because clients may send multiple `Accept:` lines
    // (the Python `mcp` SDK does: one for JSON, one for SSE).
    final acceptHeader = _readAccept(request);
    _logger.debug('Accept header: $acceptHeader');

    if (acceptHeader != null &&
        !acceptHeader.contains(contentTypeSse) &&
        !acceptHeader.contains('*/*')) {
      _logger.debug('Rejecting GET request - wrong Accept header');
      _sendErrorResponse(
        request.response,
        sessionId,
        'Not Acceptable: Client must accept text/event-stream',
        HttpStatus.notAcceptable,
      );
      return;
    }

    _logger.debug('Session validated successfully');

    // Check if GET stream already exists for this session (reconnection scenario)
    if (_getStreams.containsKey(sessionId)) {
      _logger.info('🔄 Closing existing GET stream for session $sessionId (client reconnecting)');
      final existingStream = _getStreams[sessionId];
      try {
        await existingStream?.controller.close();
      } catch (e) {
        _logger.warning('Error closing existing stream: $e');
      }
      _getStreams.remove(sessionId);
    }

    // Handle resumability
    final lastEventId = request.headers.value(lastEventIdHeader);
    if (lastEventId != null) {
      await _replayEvents(request, lastEventId, sessionId);
      return;
    }

    // Set SSE headers
    request.response.headers.set('Content-Type', contentTypeSse);
    request.response.headers.set('Cache-Control', 'no-cache, no-transform');
    request.response.headers.set('Connection', 'keep-alive');
    request.response.headers.set(mcpSessionIdHeader, sessionId);

    // Disable buffering for immediate SSE delivery
    request.response.bufferOutput = false;

    // Create GET stream for this session
    final sseController = StreamController<String>();
    _getStreams[sessionId] = SseStreamInfo(
      controller: sseController,
      response: request.response,
    );

    // Start sending SSE events with proper UTF-8 encoding
    sseController.stream.listen(
      (data) {
        _logger.debug('StreamController callback executing: sending ${data.length} bytes to response');
        request.response.add(utf8.encode(data));
        // Note: Synchronous callback for stream processing - flush happens automatically
        _logger.debug('Data added to response buffer');
      },
      onDone: () async {
        await request.response.close();
        _getStreams.remove(sessionId);
      },
      onError: (error) {
        _logger.error('GET SSE stream error for session $sessionId: $error');
        _getStreams.remove(sessionId);
      },
    );

    // Listen for client disconnect to clean up GET stream
    request.response.done.then((_) {
      _logger.info('Client disconnected for session $sessionId');
      if (_getStreams.containsKey(sessionId)) {
        _getStreams[sessionId]?.controller.close();
        _getStreams.remove(sessionId);
      }
    }).catchError((error) {
      _logger.error('Error in response.done for session $sessionId: $error');
      _getStreams.remove(sessionId);
    });

    // Send initial SSE keepalive comment to establish connection
    // This follows SSE standard practice: servers send initial event/comment
    // to confirm connection establishment and prevent HTTP response buffering
    final getStream = _getStreams[sessionId];
    if (getStream != null) {
      // Write directly to response and flush to ensure immediate delivery
      final initialData = utf8.encode(':keepalive\n\n');
      getStream.response.add(initialData);
      await getStream.response.flush();
      _logger.debug('Sent initial SSE keepalive comment and flushed GET stream');
    }

    // Send any queued responses (for JSON mode)
    if (config.isJsonResponseEnabled && _pendingResponseQueue.isNotEmpty) {
      _logger.debug('Sending ${_pendingResponseQueue.length} queued responses for session $sessionId');
      final getStream = _getStreams[sessionId];
      if (getStream != null) {
        for (final event in _pendingResponseQueue) {
          _sendSseEvent(getStream.controller, event.message, eventId: event.eventId);
        }
        _pendingResponseQueue.clear();
      }
    } else {
      _logger.debug('No queued responses to send. Queue size: ${_pendingResponseQueue.length}');
    }
  }
  
  /// Handle DELETE request (terminate session)
  Future<void> _handleDeleteRequest(HttpRequest request) async {
    // Validate Bearer token first (if configured)
    if (!_validateBearerToken(request)) {
      return;
    }

    // Extract session ID
    final sessionId = _getOrCreateSessionId(request);

    // Mark session as terminated
    _terminatedSessions.add(sessionId);
    _activeSessions.remove(sessionId);

    // Send the 204 BEFORE waiting on cleanup. Closing the GET stream's
    // StreamController used to await the response's `done` future, and
    // since the response is held open by the SSE event sink we never
    // got past it — the DELETE caller saw a connection timeout.
    // Per spec the response body for a session-terminate is empty, so
    // there's no value in deferring the status write.
    request.response.statusCode = HttpStatus.noContent;
    final responseClose = request.response.close();

    // Fire-and-forget the controller closures: they cascade into the
    // onDone callbacks which themselves close the held HTTP responses
    // for the SSE/GET streams. Awaiting them serially before
    // responding to the DELETE deadlocks under realistic clients.
    final getStream = _getStreams.remove(sessionId);
    unawaited(getStream?.controller.close() ?? Future<void>.value());
    final sessionCtrl = _sessionMessageControllers.remove(sessionId);
    unawaited(sessionCtrl?.close() ?? Future<void>.value());

    // Note: We don't close all SSE streams here, only session-specific
    // ones. Request-specific SSE streams (_sseStreams) are managed
    // per-request, not per-session.
    await responseClose;
  }
  
  /// Read the Accept header tolerating multi-value forms.
  ///
  /// `HttpHeaders.value()` throws when a header appears more than once
  /// (the Python `mcp` SDK sends two `Accept:` lines for JSON and SSE).
  /// Joining the list preserves both values for downstream parsing.
  String? _readAccept(HttpRequest request) {
    final values = request.headers['accept'];
    if (values == null || values.isEmpty) return null;
    return values.join(', ');
  }

  /// Validate Accept headers - MCP spec: POST requires both JSON and SSE
  bool _validateAcceptHeaders(HttpRequest request) {
    final acceptHeader = _readAccept(request) ?? '';
    
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
  
  /// Validate Bearer token (consistent with SSE transport)
  bool _validateBearerToken(HttpRequest request) {
    // Skip validation if no auth token is configured
    if (config.authToken == null) {
      return true;
    }
    
    final authHeader = request.headers.value('Authorization');
    if (authHeader == null || authHeader != 'Bearer ${config.authToken}') {
      _logger.debug('Bearer token validation failed - expected: Bearer ${config.authToken}, got: $authHeader');
      // MCP 2025-11-25 (RFC 9728 / SEP-985 / SEP-835): when OAuth Protected
      // Resource metadata is configured, a 401 MUST advertise where the client
      // can discover the authorization server(s) via
      // `WWW-Authenticate: Bearer resource_metadata="…"` (+ optional `scope=`
      // for step-up). Absent PRM, the challenge is omitted (prior behavior).
      final missing = authHeader == null;
      _sendErrorResponse(
        request.response,
        '',
        'Unauthorized: Invalid or missing Bearer token',
        HttpStatus.unauthorized,
        wwwAuthenticate: _buildBearerChallenge(
          error: missing ? null : 'invalid_token',
          errorDescription: missing
              ? 'Authentication required'
              : 'Invalid or missing Bearer token',
        ),
      );
      return false;
    }
    
    _logger.debug('Bearer token validation passed');
    return true;
  }
  
  /// Replay events after a given event ID (simplified implementation)
  /// Resume a session's standalone GET SSE stream after a disconnect
  /// (SEP-1699). The client reconnects with `Last-Event-ID: N`; the server
  /// opens a fresh SSE stream, replays every stored GET-stream event for this
  /// session with a numeric id greater than N (in id order), then keeps the
  /// stream open for live events. Event ids are monotonic and encode ordering
  /// so the client resumes exactly where it left off with no gaps or dupes.
  Future<void> _replayEvents(
      HttpRequest request, String lastEventId, String sessionId) async {
    final lastId = int.tryParse(lastEventId);
    if (lastId == null) {
      _sendErrorResponse(
        request.response,
        sessionId,
        'Bad Request: invalid Last-Event-ID',
        HttpStatus.badRequest,
      );
      return;
    }

    // Establish a fresh SSE stream for this session (mirrors the normal GET
    // path) so live events continue after the replay.
    request.response.headers.set('Content-Type', contentTypeSse);
    request.response.headers.set('Cache-Control', 'no-cache, no-transform');
    request.response.headers.set('Connection', 'keep-alive');
    request.response.headers.set(mcpSessionIdHeader, sessionId);
    request.response.bufferOutput = false;

    final sseController = StreamController<String>();
    _getStreams[sessionId] = SseStreamInfo(
      controller: sseController,
      response: request.response,
    );
    sseController.stream.listen(
      (data) => request.response.add(utf8.encode(data)),
      onDone: () async {
        await request.response.close();
        _getStreams.remove(sessionId);
      },
      onError: (error) {
        _logger.error('Resumed GET SSE stream error for $sessionId: $error');
        _getStreams.remove(sessionId);
      },
    );
    request.response.done.then((_) {
      _getStreams[sessionId]?.controller.close();
      _getStreams.remove(sessionId);
    }).catchError((error) {
      _logger.error('Error in resumed response.done for $sessionId: $error');
      _getStreams.remove(sessionId);
    });

    // Replay stored GET-stream events for this session after `lastId`,
    // ordered by numeric event id. Broadcasts (null target) and events
    // targeted at this session are eligible; per-request POST responses and
    // other sessions' targeted events are not.
    final replay = _eventStore.entries
        .where((e) {
          final id = int.tryParse(e.key);
          return id != null && id > lastId;
        })
        .where((e) =>
            e.value.forGetStream &&
            (e.value.targetSessionId == null ||
                e.value.targetSessionId == sessionId))
        .toList()
      ..sort((a, b) => int.parse(a.key).compareTo(int.parse(b.key)));

    for (final entry in replay) {
      _sendSseEvent(sseController, entry.value.message,
          eventId: entry.value.eventId);
    }
  }
  
  /// Validate that the message is a JSON-RPC 2.0 envelope.
  ///
  /// Accepts the three legal shapes per spec:
  ///   - request: `{jsonrpc, id, method, params?}`
  ///   - notification: `{jsonrpc, method, params?}` (no id)
  ///   - response: `{jsonrpc, id, result | error}` (no method)
  ///
  /// Earlier versions required `method` for every POST, which silently
  /// rejected client → server responses to outbound server-initiated
  /// requests (sampling/createMessage etc.) — the response then sat
  /// dropped while the originating tool waited for a reply.
  /// Reserved transport-internal control keys the transport sets on messages
  /// it hands to the server. A client must never be able to supply them, so
  /// they are stripped from decoded client input at every ingestion boundary
  /// (in particular `_stateless`, which routes to the 2026-07-28 stateless
  /// handler).
  static const _reservedControlKeys = {
    '_stateless',
    '_protocolVersion',
    '_sessionId',
    '_authorization',
  };

  /// The bearer credential on this request, or null when the request carries
  /// no `Authorization: Bearer` header.
  ///
  /// A JSON-RPC handler never sees the HTTP request, so a token that arrives
  /// the way the specification says it does — a header — had no route to
  /// `Server.enableAuthentication`'s validator, which looked only at the
  /// message body and the session. That left header authentication, the form
  /// every standard client sends, unable to reach the validator at all.
  ///
  /// The credential is carried on the reserved `_authorization` control key,
  /// which is stripped from client input at every ingestion boundary, so a
  /// request body cannot present one the transport did not read off the wire.
  ///
  /// Independent of `config.authToken`: that is a static shared secret the
  /// transport compares itself, and a deployment using per-user tokens does
  /// not set it.
  static String? _bearerCredential(HttpRequest request) {
    final header = request.headers.value('Authorization');
    if (header == null) return null;
    const scheme = 'bearer ';
    if (header.length <= scheme.length) return null;
    if (header.substring(0, scheme.length).toLowerCase() != scheme) return null;
    final credential = header.substring(scheme.length).trim();
    return credential.isEmpty ? null : credential;
  }

  void _stripReservedKeys(Map<String, dynamic> message) {
    for (final k in _reservedControlKeys) {
      message.remove(k);
    }
  }

  bool _isValidJsonRpc(Map<String, dynamic> message) {
    if (message['jsonrpc'] != '2.0') return false;
    final hasMethod = message['method'] is String;
    final hasResult = message.containsKey('result');
    final hasError = message['error'] is Map;
    final hasId = message.containsKey('id');
    if (hasMethod) return true; // request or notification
    if (hasId && (hasResult || hasError)) return true; // response
    return false;
  }
  
  /// DNS-rebinding protection (MCP 2025-11-25). Returns `true` when the
  /// request may proceed:
  /// - always `true` when `config.allowedOrigins` is null (enforcement off);
  /// - always `true` when the request carries no `Origin` header
  ///   (non-browser clients are not subject to rebinding);
  /// - otherwise `true` only if the `Origin` value is in the allow-list.
  bool _isOriginAllowed(HttpRequest request) {
    if (config.allowAnyOrigin) return true;
    final origin = request.headers.value('origin');
    // A request with no `Origin` did not come from a browser, so it cannot be
    // a rebinding attempt.
    if (origin == null) return true;
    final allowed = config.allowedOrigins;
    if (allowed != null) return allowed.contains(origin);
    return _isLoopbackOrigin(origin);
  }

  /// Whether an `Origin` names the local machine.
  ///
  /// The default allow-list, because a rebinding attack works by pointing a
  /// public page at a local server: a page served from the same machine is
  /// not that attack, and everything else has to be named explicitly.
  static bool _isLoopbackOrigin(String origin) {
    final uri = Uri.tryParse(origin);
    if (uri == null) return false;
    final host = uri.host;
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  /// Build the `WWW-Authenticate: Bearer …` challenge for a 401 response
  /// (RFC 9728 / SEP-985, incremental scope SEP-835).
  ///
  /// Returns `null` when no OAuth Protected Resource metadata is configured —
  /// in that case the transport emits a bare 401 with no challenge, preserving
  /// prior behavior. When PRM is configured, the challenge always carries
  /// `resource_metadata="<url>"` pointing at the well-known document
  /// (`<resource>/.well-known/oauth-protected-resource`) so the client can
  /// discover the authorization server(s). `error`/`error_description` and a
  /// config-driven `scope` (SEP-835) are appended when available.
  String? _buildBearerChallenge({String? error, String? errorDescription}) {
    final prm = _protectedResourceMetadataProvider?.call();
    if (prm == null) return null;

    final resource = prm['resource'] as String?;
    final rmUrl = _resourceMetadataUrl(resource);

    final params = <String>['resource_metadata="$rmUrl"'];
    if (error != null) params.add('error="$error"');
    if (errorDescription != null) {
      params.add('error_description="$errorDescription"');
    }
    // SEP-835 incremental scope: advertise only when explicitly configured —
    // PRM `scopes_supported` is the *supported* set, not necessarily the
    // *required* scope for this request, so it is not auto-advertised here.
    final scope = config.challengeScope;
    if (scope != null && scope.isNotEmpty) {
      params.add('scope="$scope"');
    }
    return 'Bearer ${params.join(', ')}';
  }

  /// Derive the RFC 9728 well-known metadata URL for a resource identifier.
  ///
  /// Per RFC 9728 §3.1 the path component `/.well-known/oauth-protected-
  /// resource` is inserted between the resource's host and any path. For an
  /// origin-only resource (`https://api.example.com`) this yields
  /// `https://api.example.com/.well-known/oauth-protected-resource`.
  String _resourceMetadataUrl(String? resource) {
    const wellKnown = '/.well-known/oauth-protected-resource';
    if (resource == null || resource.isEmpty) return wellKnown;
    final uri = Uri.tryParse(resource);
    if (uri == null || !uri.hasScheme) {
      // Fall back to a plain suffix when the value is not a parseable URI.
      final trimmed = resource.endsWith('/')
          ? resource.substring(0, resource.length - 1)
          : resource;
      return '$trimmed$wellKnown';
    }
    final path = uri.path;
    if (path.isEmpty || path == '/') {
      return '${uri.origin}$wellKnown';
    }
    // Insert the well-known path before the resource path (RFC 9728 §3.1).
    final normalizedPath = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    return '${uri.origin}$wellKnown$normalizedPath';
  }

  /// Set CORS headers
  void _setCorsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', config.corsConfig.allowOrigin);
    response.headers.set('Access-Control-Allow-Methods', config.corsConfig.allowMethods);
    response.headers.set('Access-Control-Allow-Headers', config.corsConfig.allowHeaders);
    response.headers.set('Access-Control-Expose-Headers', config.corsConfig.exposeHeaders);
    response.headers.set('Access-Control-Max-Age', config.corsConfig.maxAge.toString());
  }
  
  /// Send error response
  ///
  /// [wwwAuthenticate], when non-null, is set as the `WWW-Authenticate`
  /// response header (RFC 9728 / SEP-985 auth challenge on a 401). It is null
  /// for every non-auth error path, preserving prior behavior.
  void _sendErrorResponse(HttpResponse response, String sessionId,
      String message, int statusCode,
      {String? wwwAuthenticate}) {
    response.statusCode = statusCode;
    response.headers.set('Content-Type', 'application/json; charset=utf-8');
    if (sessionId.isNotEmpty) {
      response.headers.set(mcpSessionIdHeader, sessionId);
    }
    if (wwwAuthenticate != null) {
      response.headers.set('WWW-Authenticate', wwwAuthenticate);
    }

    final error = {
      'error': message,
    };

    response.add(utf8.encode(jsonEncode(error)));
    response.close();
  }

  /// Send JSON-RPC error
  void _sendJsonRpcError(
    HttpResponse response,
    String sessionId,
    dynamic id,
    int code,
    String message,
    String? data,
  ) {
    response.statusCode = HttpStatus.ok;
    response.headers.set('Content-Type', 'application/json; charset=utf-8');
    if (sessionId.isNotEmpty) {
      response.headers.set(mcpSessionIdHeader, sessionId);
    }

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
  
  /// Route a server message to an open 2026-07-28 `subscriptions/listen` SSE
  /// stream (SEP-2577). Returns true if the message was consumed by a
  /// subscription stream:
  ///  - a notification whose `params._meta.subscriptionId` names an open stream
  ///    (stays open), or
  ///  - a response whose `id` names an open stream (the terminal
  ///    `SubscriptionsListenResult` → deliver, then close the stream).
  ///
  /// Both matches are keyed by (session, subscriptionId): the session half is
  /// `_targetSessionId`, stamped by the server on every subscription message.
  /// A message without it cannot name a subscription stream and falls through.
  bool _routeStatelessSubscription(Map message) {
    final targetSessionId = message['_targetSessionId'];
    if (targetSessionId is! String) return false;
    final isResponse =
        message.containsKey('id') && !message.containsKey('method');
    if (isResponse) {
      final key = _inflightKey(targetSessionId, message['id']);
      final controller = _statelessSubscriptionStreams[key];
      if (controller == null) return false;
      final clean = Map<String, dynamic>.from(message)..remove('_targetSessionId');
      _sendSseEvent(controller, clean);
      if (!controller.isClosed) controller.close();
      _statelessSubscriptionStreams.remove(key);
      return true;
    }
    // Notification: match on `params._meta.subscriptionId`.
    final params = message['params'];
    if (params is! Map) return false;
    final meta = params['_meta'];
    final subId =
        meta is Map ? meta['io.modelcontextprotocol/subscriptionId'] : null;
    if (subId == null) return false;
    final controller =
        _statelessSubscriptionStreams[_inflightKey(targetSessionId, subId)];
    if (controller == null) return false;
    final clean = Map<String, dynamic>.from(message)..remove('_targetSessionId');
    _sendSseEvent(controller, clean);
    return true;
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

      // 2026-07-28 `subscriptions/listen` (SEP-2577) routing. Route to the
      // long-lived SSE stream keyed by subscriptionId, BEFORE the normal
      // response/notification handling below. Legacy paths are unaffected — a
      // message only matches when its id (terminal result) or its
      // `_meta.subscriptionId` (stream notification) names an open subscription.
      if (message is Map && _statelessSubscriptionStreams.isNotEmpty) {
        if (_routeStatelessSubscription(message)) return;
      }

      // A message is a JSON-RPC RESPONSE only when it has an id AND no
      // method (i.e. it carries `result` or `error`). A server-INITIATED
      // request (e.g., `sampling/createMessage`, `elicitation/create`)
      // also has an id but is NOT a response — it must be routed to the
      // standalone GET stream so the client can pick it up. The earlier
      // `containsKey('id')` check sent every id-bearing message into
      // the response-completion path, which dropped outbound
      // server-initiated requests on the floor with `No pending request
      // found for response with ID: srv-N`.
      final isResponse = message is Map &&
          message.containsKey('id') &&
          !message.containsKey('method');

      if (isResponse) {
        final requestId = message['id'];

        // Session half of the in-flight key, stamped by `Server._sendResponse`
        // / `_sendErrorResponse`. Without it a response cannot be attributed to
        // a session, and matching on the bare id would be exactly the collision
        // this key exists to prevent — so drop it rather than guess.
        final targetSessionId = message['_targetSessionId'];
        if (targetSessionId is! String) {
          _logger.error(
              'Dropping response id=$requestId: no _targetSessionId. A response '
              'must be routed by (session, id); matching on the bare id would '
              'cross sessions.');
          return;
        }
        final inflightKey = _inflightKey(targetSessionId, requestId);
        _logger.debug('Response $inflightKey (id type: ${requestId.runtimeType})');

        // Internal routing metadata never reaches the wire.
        final outbound = Map<String, dynamic>.from(message)
          ..remove('_targetSessionId');

        // 2026-07-28 stateless: resolve the one-shot completer independent of
        // the JSON/SSE response-mode config. Checked first so a stateless
        // reply never falls into the session-scoped SSE/JSON routing below.
        final statelessCompleter = _statelessCompleters.remove(inflightKey);
        if (statelessCompleter != null) {
          if (!statelessCompleter.isCompleted) {
            statelessCompleter.complete(outbound);
          }
          return;
        }

        // JSON-RPC batch entry: resolve the batch completer independent of the
        // response-mode config (the batch is answered as one JSON array in
        // `_handleBatchRequest`). Checked before the mode-scoped routing below.
        final batchCompleter = _batchCompleters[inflightKey];
        if (batchCompleter != null) {
          if (!batchCompleter.isCompleted) {
            batchCompleter.complete(outbound);
          }
          return;
        }

        // Generate event ID for resumability
        final eventId = (_eventIdCounter++).toString();

        // Store event for resumability
        _eventStore[eventId] = EventMessage(
          message: outbound,
          eventId: eventId,
        );

        // Handle based on mode
        if (config.isJsonResponseEnabled) {
          if (config.jsonResponseMode == 'sync') {
            // Synchronous JSON mode: complete the pending completer
            final completer = _pendingCompleters.remove(inflightKey);
            if (completer != null) {
              try {
                completer.complete(outbound);
                _logger.debug('Completed completer for request $inflightKey');
              } catch (e, stackTrace) {
                _logger.error('Error completing completer for $inflightKey: $e');
                _logger.debug('Stack trace: $stackTrace');
              }
            } else {
              _logger.warning('No pending completer for response $inflightKey');
              _logger.debug('Available completers: ${_pendingCompleters.keys.toList()}');
            }
          } else {
            // Asynchronous JSON mode: store response for polling. The store key
            // and the in-flight key are the same `<session>:<id>` shape.
            if (_pendingRequests.remove(inflightKey) != null) {
              _responseStore[inflightKey] = outbound;
              _responseTimestamps[inflightKey] = DateTime.now();
            } else {
              _logger.warning('No pending request for async response $inflightKey');
            }
          }
        } else if (_sseStreams.containsKey(inflightKey)) {
          // SSE response for specific request
          final stream = _sseStreams[inflightKey]!;
          _sendSseEvent(stream.controller, outbound, eventId: eventId);

          // If this is a response or error, close the stream
          if (message.containsKey('result') || message.containsKey('error')) {
            stream.controller.close();
            _sseStreams.remove(inflightKey);
            _messageRouters.remove(inflightKey)?.close();
          }
        } else {
          // Log when we can't find a pending request for a response
          _logger.warning('No pending request found for response $inflightKey');
          _logger.debug('Current pending requests: ${_pendingRequests.keys.toList()}');
          _logger.debug('Current SSE streams: ${_sseStreams.keys.toList()}');
        }
      } else {
        // Notification or server-initiated message
        final eventId = (_eventIdCounter++).toString();

        // Remove internal metadata before storing and sending
        final cleanMessage = Map<String, dynamic>.from(message);
        final targetSessionId = cleanMessage.remove('_targetSessionId') as String?;

        // GET-stream event (notification / broadcast) — eligible for replay
        // on a `Last-Event-ID` reconnect. Broadcasts carry a null target.
        _eventStore[eventId] = EventMessage(
          message: cleanMessage,
          eventId: eventId,
          forGetStream: true,
          targetSessionId: targetSessionId,
        );

        var sent = false;

        // If target session is specified, send only to that session's GET stream
        if (targetSessionId != null && _getStreams.containsKey(targetSessionId)) {
          _logger.debug('📤 Sending notification to target session: $targetSessionId');
          _sendSseEvent(_getStreams[targetSessionId]!.controller, cleanMessage, eventId: eventId);
          sent = true;
        } else if (targetSessionId == null) {
          // Broadcast mode: send to all GET streams
          for (final entry in _getStreams.entries) {
            _logger.debug('📤 Broadcasting notification to GET stream (session: ${entry.key})');
            _sendSseEvent(entry.value.controller, cleanMessage, eventId: eventId);
            sent = true;
          }

          // If no GET stream available, send to all active POST SSE streams
          if (!sent && _sseStreams.isNotEmpty) {
            _logger.debug('No GET stream available, sending to ${_sseStreams.length} active POST SSE streams');
            for (final entry in _sseStreams.entries) {
              _logger.debug('📤 Broadcasting notification to POST SSE stream (requestId: ${entry.key})');
              _sendSseEvent(entry.value.controller, cleanMessage, eventId: eventId);
              sent = true;
            }
          }
        } else {
          _logger.warning('Target session $targetSessionId not found or no GET stream available');
        }

        if (!sent) {
          _logger.debug('No streams available to send notification');
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

    // Close all GET streams
    for (final stream in _getStreams.values) {
      await stream.controller.close();
    }
    _getStreams.clear();

    // Close any open 2026-07-28 `subscriptions/listen` SSE streams (SEP-2577).
    for (final controller in _statelessSubscriptionStreams.values) {
      if (!controller.isClosed) await controller.close();
    }
    _statelessSubscriptionStreams.clear();
    
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
  final String sessionId;

  _PendingRequest({
    required this.request,
    required this.timestamp,
    required this.sessionId,
  });
}