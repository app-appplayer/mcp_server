import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../logger.dart';

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
class StdioServerTransport implements ServerTransport {
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  StreamSubscription? _stdinSubscription;

  StdioServerTransport() {
    _initialize();
  }

  void _initialize() {
    log.debug('[Flutter MCP] Initializing STDIO transport');

    _stdinSubscription = stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.isNotEmpty)
        .map((line) {
      try {
        log.debug('[Flutter MCP] Raw received line: $line');
        final parsedMessage = jsonDecode(line);
        log.debug('[Flutter MCP] Parsed message: $parsedMessage');
        return parsedMessage;
      } catch (e) {
        log.debug('[Flutter MCP] JSON parsing error: $e');
        log.debug('[Flutter MCP] Problematic line: $line');
        return null;
      }
    })
        .where((message) => message != null)
        .listen(
          (message) {
        log.debug('[Flutter MCP] Processing message: $message');
        if (!_messageController.isClosed) {
          _messageController.add(message);
        }
      },
      onError: (error) {
        log.debug('[Flutter MCP] Stream error: $error');
        _handleTransportError(error);
      },
      onDone: () {
        log.debug('[Flutter MCP] stdin stream done');
        _handleStreamClosure();
      },
      cancelOnError: false,
    );
  }

  void _handleTransportError(dynamic error) {
    log.debug('[Flutter MCP] Transport error: $error');
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.completeError(error);
    }
    _cleanup();
  }

  void _handleStreamClosure() {
    log.debug('[Flutter MCP] Handling stream closure');
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }
    _cleanup();
  }

  void _cleanup() {
    _stdinSubscription?.cancel();
    if (!_messageController.isClosed) {
      _messageController.close();
    }
  }

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) {
    try {
      final jsonMessage = jsonEncode(message);
      log.debug('Encoding message: $message');
      log.debug('Encoded JSON: $jsonMessage');

      stdout.writeln(jsonMessage);
      stdout.flush();

      log.debug('[MCP] Sent message: $jsonMessage');
    } catch (e) {
      log.debug('Error encoding message: $e');
      log.debug('Original message: $message');
      rethrow;
    }
  }

  @override
  void close() {
    log.debug('[MCP] Closing StdioServerTransport');
    _cleanup();
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
      log.debug('[MCP] Server listening on port $port');
    } catch (e) {
      log.debug('[MCP] Failed to start server on port $port: $e');

      if (fallbackPorts != null && fallbackPorts!.isNotEmpty) {
        for (final fallbackPort in fallbackPorts!) {
          try {
            _server = await _startServer(fallbackPort);
            log.debug('[MCP] Server listening on fallback port $fallbackPort');
            break;
          } catch (e) {
            log.debug('[MCP] Failed to start server on fallback port $fallbackPort: $e');
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
        log.debug('[SSE] Unauthorized access attempt.');
        return;
      }
    }

    final sessionId = DateTime.now().millisecondsSinceEpoch.toString();
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
    log.debug('[SSE] Sent connection_established message: $sessionId');

    _sessionClients[sessionId] = request.response;

    request.response.done.then((_) {
      log.debug('[SSE] Client disconnected: $sessionId');
      _sessionClients.remove(sessionId);
    }).catchError((e) {
      log.debug('[SSE] Client error: $sessionId - $e');
      _sessionClients.remove(sessionId);
    });
  }

  void _setCorsHeaders(HttpResponse response) {
    response.headers
      ..add('Access-Control-Allow-Origin', '*')
      ..add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..add('Access-Control-Allow-Headers', 'Content-Type, Authorization')
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
      log.debug('[SSE] Unauthorized message attempt with invalid sessionId: $sessionId');
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

    for (final client in List.from(_sessionClients.values)) {
      try {
        client
          ..write(eventData)
          ..flush();
      } catch (e) {
        log.debug('[SSE] Error sending message: $e');
      }
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

/// Mock transport for testing
class MockTransport implements ServerTransport {
  final void Function(dynamic)? onSendCallback;
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();

  MockTransport({this.onSendCallback});

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) {
    if (onSendCallback != null) {
      onSendCallback!(message);
    }
  }

  @override
  void close() {
    _closeCompleter.complete();
    _messageController.close();
  }

  void receiveMessage(dynamic message) {
    if (!_messageController.isClosed) {
      _messageController.add(message);
    }
  }
}