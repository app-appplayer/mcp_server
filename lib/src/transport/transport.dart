import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../logger.dart';

final Logger _logger = Logger.getLogger('mcp_server.transport');

/// Abstract base class for server transport implementations
abstract class ServerTransport {
  /// Stream of incoming messages
  Stream<dynamic> get onMessage;

  /// Future that completes when the transport is closed
  Future<void> get onClose;

  /// Send a message through the transport
  void send(dynamic message);

  /// Close the transport
  void close();
}

/// Transport implementation using standard input/output streams
// StdioServerTransport class with singleton pattern and improved error handling
class StdioServerTransport implements ServerTransport {
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  StreamSubscription? _stdinSubscription;

  late final IOSink _stdoutSink;

  // Static instance for singleton pattern
  static StdioServerTransport? _instance;

  // Flag to check if the transport has been closed
  bool _isClosed = false;

  // Factory constructor to implement singleton pattern
  factory StdioServerTransport() {
    if (_instance != null) {
      _logger.debug('Reusing existing StdioServerTransport instance');
      return _instance!;
    }

    _logger.debug('Creating new StdioServerTransport instance');
    _instance = StdioServerTransport._internal();
    return _instance!;
  }

  // Private constructor for singleton implementation
  StdioServerTransport._internal() {
    _stdoutSink = IOSink(stdout);
    _initialize();
  }

  void _initialize() {
    _logger.debug('Initializing STDIO transport');

    try {
      _stdinSubscription = stdin
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((line) => line.isNotEmpty)
          .map((line) {
            try {
              _logger.debug('Raw received line: $line');
              final parsedMessage = jsonDecode(line);
              _logger.debug('Parsed message: $parsedMessage');
              return parsedMessage;
            } catch (e) {
              _logger.debug('JSON parsing error: $e');
              _logger.debug('Problematic line: $line');
              return null;
            }
          })
          .where((message) => message != null)
          .listen(
            (message) {
              _logger.debug('Processing message: $message');
              if (!_messageController.isClosed) {
                _messageController.add(message);
              }
            },
            onError: (error) {
              _logger.debug('Stream error: $error');
              _handleTransportError(error);
            },
            onDone: () {
              _logger.debug('stdin stream done');
              _handleStreamClosure();
            },
            cancelOnError: false,
          );
    } catch (e) {
      _logger.debug('Error initializing STDIO transport: $e');
      _handleTransportError(e);
    }
  }

  void _handleTransportError(dynamic error) {
    _logger.debug('Transport error: $error');
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.completeError(error);
    }
    _cleanup();
  }

  void _handleStreamClosure() {
    _logger.debug('Handling stream closure');
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }
    _cleanup();
  }

  void _cleanup() {
    if (_isClosed) return;

    _isClosed = true;
    _stdinSubscription?.cancel();

    if (!_messageController.isClosed) {
      _messageController.close();
    }
    try {
      _stdoutSink.close();
    } catch (e) {
      _logger.debug('Error closing stdout sink: $e');
    }
  }

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) {
    if (_isClosed) {
      _logger.debug('Attempted to send message on closed transport');
      return;
    }

    try {
      final jsonMessage = jsonEncode(message);
      _logger.debug('Encoding message: $message');
      _logger.debug('Encoded JSON: $jsonMessage');

      // Check if stdout is available and not bound
      try {
        _stdoutSink.writeln(jsonMessage);
        _logger.debug('Sent message: $jsonMessage');
      } catch (e) {
        // If there's a StreamSink binding issue, handle gracefully
        if (e.toString().contains('StreamSink is bound')) {
          _logger.debug('StreamSink binding issue detected: $e');
          _handleTransportError('StreamSink binding conflict');
        } else {
          rethrow;
        }
      }
    } catch (e) {
      _logger.debug('Error encoding or sending message: $e');
      _logger.debug('Original message: $message');
      // Don't rethrow to prevent process crash
    }
  }

  @override
  void close() {
    _logger.debug('Closing StdioServerTransport');
    _cleanup();
    // Clear singleton instance on close
    if (_instance == this) {
      _instance = null;
    }
  }
}

/// Transport implementation using Server-Sent Events (SSE) over HTTP
class SseServerTransport implements ServerTransport {
  final String endpoint;
  final String messagesEndpoint;
  final int port;
  final List<int>? fallbackPorts;
  final String? authToken;

  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();

  HttpServer? _server;
  final _sessionClients = <String, HttpResponse>{};

  // Add a callback to notify when a new session is created
  void Function(String sessionId, Map<String, String> headers)? onSessionCreate;

  SseServerTransport({
    required this.endpoint,
    required this.messagesEndpoint,
    required this.port,
    this.fallbackPorts,
    this.authToken,
  }) {
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      _server = await _startServer(port);
      _logger.debug('Server listening on port $port');
    } catch (e) {
      _logger.debug('Failed to start server on port $port: $e');

      if (fallbackPorts != null && fallbackPorts!.isNotEmpty) {
        for (final fallbackPort in fallbackPorts!) {
          try {
            _server = await _startServer(fallbackPort);
            _logger.debug('Server listening on fallback port $fallbackPort');
            break;
          } catch (e) {
            _logger.debug(
                'Failed to start server on fallback port $fallbackPort: $e');
          }
        }
      }

      if (_server == null) {
        _closeCompleter.completeError('Failed to start server on any port');
      }
    }
  }

  Future<HttpServer> _startServer(int port) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);

    server.listen((HttpRequest request) {
      if (request.uri.path == endpoint) {
        _handleSseConnection(request);
      } else if (request.uri.path == messagesEndpoint) {
        _handleMessageRequest(request);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.close();
      }
    });

    return server;
  }

  void _handleSseConnection(HttpRequest request) async {
    if (request.method == 'OPTIONS') {
      _setCorsHeaders(request.response);
      request.response
        ..statusCode = HttpStatus.ok
        ..close();
      return;
    }

    if (authToken != null) {
      final authHeader = request.headers.value('Authorization');
      if (authHeader == null || authHeader != 'Bearer $authToken') {
        _setCorsHeaders(request.response);
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.add('Content-Type', 'application/json')
          ..write(jsonEncode({'error': 'Unauthorized'}))
          ..close();
        _logger.debug('[SSE] Unauthorized access attempt.');
        return;
      }
    }

    final sessionId = DateTime.now().millisecondsSinceEpoch.toString();

    // Extract headers
    final headers = <String, String>{};
    request.headers.forEach((name, values) {
      headers[name] = values.join(', ');
    });
    
    // Notify server of new session and headers
    if (onSessionCreate != null) {
      onSessionCreate!(sessionId, headers);
    }

    _setCorsHeaders(request.response);
    request.response.headers
      ..add('Content-Type', 'text/event-stream')
      ..add('Cache-Control', 'no-cache')
      ..add('Connection', 'keep-alive')
      ..add('X-Session-Id', sessionId);

    request.response.bufferOutput = false;

    request.response.write('event: endpoint\n');
    final endpointUrl = '/message?sessionId=$sessionId';
    request.response.write('data: $endpointUrl\n\n');
    await request.response.flush();
    _logger.debug('[SSE] Sent connection_established message: $sessionId');

    _sessionClients[sessionId] = request.response;

    request.response.done.then((_) {
      _logger.debug('[SSE] Client disconnected: $sessionId');
      _sessionClients.remove(sessionId);

      if (_sessionClients.isEmpty && !_closeCompleter.isCompleted) {
        _logger.info('[SSE] All clients disconnected, completing onClose');
        _closeCompleter.complete();
      }
    }).catchError((e) {
      _logger.debug('[SSE] Client error: $sessionId - $e');
      _sessionClients.remove(sessionId);

      if (_sessionClients.isEmpty && !_closeCompleter.isCompleted) {
        _logger.info(
            '[SSE] All clients disconnected (after error), completing onClose');
        _closeCompleter.complete();
      }
    });
  }

  void _setCorsHeaders(HttpResponse response) {
    response.headers
      ..add('Access-Control-Allow-Origin', '*')
      ..add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..add('Access-Control-Allow-Headers',
          'Content-Type, Authorization, accept, cache-control')
      ..add('Access-Control-Max-Age', '86400');
  }

  Future<void> _handleMessageRequest(HttpRequest request) async {
    if (request.method == 'OPTIONS') {
      _setCorsHeaders(request.response);
      request.response
        ..statusCode = HttpStatus.ok
        ..close();
      return;
    }

    final sessionId = request.uri.queryParameters['sessionId'];

    if (sessionId == null || !_sessionClients.containsKey(sessionId)) {
      _setCorsHeaders(request.response);
      request.response
        ..statusCode = HttpStatus.unauthorized
        ..headers.add('Content-Type', 'application/json')
        ..write(jsonEncode({'error': 'Unauthorized or Invalid session'}));
      await request.response.close();
      _logger.debug(
          '[SSE] Unauthorized message attempt with invalid sessionId: $sessionId');
      return;
    }

    if (request.method != 'POST') {
      _setCorsHeaders(request.response);
      request.response
        ..statusCode = HttpStatus.methodNotAllowed
        ..close();
      return;
    }

    try {
      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body);

      if (message is Map && message['jsonrpc'] == '2.0') {
        _messageController.add(message);

        _setCorsHeaders(request.response);
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.add('Content-Type', 'application/json')
          ..write(jsonEncode({'status': 'ok'}));
      } else {
        throw FormatException('Invalid JSON-RPC message');
      }
    } catch (e) {
      _setCorsHeaders(request.response);
      request.response
        ..statusCode = HttpStatus.badRequest
        ..headers.add('Content-Type', 'application/json')
        ..write(jsonEncode({'error': e.toString()}));
    }

    await request.response.close();
  }

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) {
    final jsonString = jsonEncode(message);
    final eventData = 'event: message\ndata: $jsonString\n\n';

    // Store sessions to remove if sending fails
    final toRemove = <String>[];

    _sessionClients.forEach((sessionId, client) {
      final success = _sendToClient(client, eventData);
      if (!success) {
        _logger.debug('[SSE] Removing disconnected client: $sessionId');
        toRemove.add(sessionId);
      }
    });

    for (final id in toRemove) {
      _sessionClients.remove(id);
    }
  }

  /// Safely sends data to a client, returns false if an error occurred
  bool _sendToClient(HttpResponse client, String data) {
    try {
      client.write(data);
      client.flush();
      return true;
    } catch (e) {
      _logger.debug('[SSE] Failed to send to client: $e');
      return false;
    }
  }

  @override
  void close() async {
    for (final client in _sessionClients.values) {
      await client.close();
    }
    _sessionClients.clear();

    await _server?.close(force: true);
    _messageController.close();

    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }
  }
}
