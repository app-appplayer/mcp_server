import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    stderr.writeln('[Flutter MCP] Initializing STDIO transport');

    _stdinSubscription = stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.isNotEmpty)
        .map((line) {
      try {
        stderr.writeln('[Flutter MCP] Raw received line: $line');
        final parsedMessage = jsonDecode(line);
        stderr.writeln('[Flutter MCP] Parsed message: $parsedMessage');
        return parsedMessage;
      } catch (e) {
        stderr.writeln('[Flutter MCP] JSON parsing error: $e');
        stderr.writeln('[Flutter MCP] Problematic line: $line');
        return null;
      }
    })
        .where((message) => message != null)
        .listen(
          (message) {
        stderr.writeln('[Flutter MCP] Processing message: $message');
        if (!_messageController.isClosed) {
          _messageController.add(message);
        }
      },
      onError: (error) {
        stderr.writeln('[Flutter MCP] Stream error: $error');
        _handleTransportError(error);
      },
      onDone: () {
        stderr.writeln('[Flutter MCP] stdin stream done');
        _handleStreamClosure();
      },
      cancelOnError: false,
    );
  }

  void _handleTransportError(dynamic error) {
    stderr.writeln('[Flutter MCP] Transport error: $error');
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.completeError(error);
    }
    _cleanup();
  }

  void _handleStreamClosure() {
    stderr.writeln('[Flutter MCP] Handling stream closure');
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
      stderr.writeln('Encoding message: $message');
      stderr.writeln('Encoded JSON: $jsonMessage');

      stdout.writeln(jsonMessage);
      stdout.flush();

      stderr.writeln('[Flutter MCP] Sent message: $jsonMessage');
    } catch (e) {
      stderr.writeln('Error encoding message: $e');
      stderr.writeln('Original message: $message');
      rethrow;
    }
  }

  @override
  void close() {
    stderr.writeln('[Flutter MCP] Closing StdioServerTransport');
    _cleanup();
  }
}

/// Transport implementation using Server-Sent Events (SSE) over HTTP
class SseServerTransport implements ServerTransport {
  final String endpoint;
  final String messagesEndpoint;
  final int port;
  final List<int>? fallbackPorts;

  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();

  HttpServer? _server;
  final _clients = <HttpResponse>[];

  SseServerTransport({
    required this.endpoint,
    required this.messagesEndpoint,
    required this.port,
    this.fallbackPorts,
  }) {
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      _server = await _startServer(port);
      stderr.writeln('[MCP] Server listening on port $port');
    } catch (e) {
      stderr.writeln('[MCP] Failed to start server on port $port: $e');

      // Try fallback ports if provided
      if (fallbackPorts != null && fallbackPorts!.isNotEmpty) {
        for (final fallbackPort in fallbackPorts!) {
          try {
            _server = await _startServer(fallbackPort);
            stderr.writeln('[MCP] Server listening on fallback port $fallbackPort');
            break;
          } catch (e) {
            stderr.writeln('[MCP] Failed to start server on fallback port $fallbackPort: $e');
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

  void _handleSseConnection(HttpRequest request) {
    request.response.headers.add('Content-Type', 'text/event-stream');
    request.response.headers.add('Cache-Control', 'no-cache');
    request.response.headers.add('Connection', 'keep-alive');
    request.response.headers.add('Access-Control-Allow-Origin', '*');

    _clients.add(request.response);

    request.response.done.then((_) {
      _clients.remove(request.response);
    }).catchError((e) {
      _clients.remove(request.response);
    });
  }

  Future<void> _handleMessageRequest(HttpRequest request) async {
    request.response.headers.add('Access-Control-Allow-Origin', '*');

    if (request.method == 'OPTIONS') {
      request.response.headers.add('Access-Control-Allow-Methods', 'POST, OPTIONS');
      request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');
      request.response.statusCode = HttpStatus.ok;
      request.response.close();
      return;
    }

    if (request.method != 'POST') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      request.response.close();
      return;
    }

    try {
      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body);
      _messageController.add(message);

      request.response.statusCode = HttpStatus.ok;
      request.response.close();
    } catch (e) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('Error parsing request: $e');
      request.response.close();
    }
  }

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) {
    final jsonMessage = jsonEncode(message);
    final eventData = 'data: $jsonMessage\n\n';

    for (final client in List.from(_clients)) {
      try {
        client.write(eventData);
      } catch (e) {
        stderr.writeln('Error sending message to client: $e');
        _clients.remove(client);
      }
    }
  }

  @override
  void close() async {
    for (final client in _clients) {
      await client.close();
    }
    _clients.clear();

    await _server?.close(force: true);
    _messageController.close();

    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }
  }
}