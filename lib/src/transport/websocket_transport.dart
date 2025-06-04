/// WebSocket transport implementation for MCP server
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../logger.dart';

final Logger _logger = Logger('mcp_server.websocket_transport');

/// Configuration for WebSocket transport
class WebSocketConfig {
  /// Port to listen on
  final int port;
  
  /// Path for WebSocket endpoint
  final String path;
  
  /// Ping interval for keepalive
  final Duration pingInterval;
  
  /// Pong timeout before considering connection dead
  final Duration pongTimeout;
  
  /// Whether to enable compression
  final bool enableCompression;
  
  /// Maximum message size in bytes
  final int maxMessageSize;
  
  const WebSocketConfig({
    required this.port,
    this.path = '/ws',
    this.pingInterval = const Duration(seconds: 30),
    this.pongTimeout = const Duration(seconds: 10),
    this.enableCompression = true,
    this.maxMessageSize = 1024 * 1024, // 1MB
  });
}

/// WebSocket client connection
class WebSocketConnection {
  final String id;
  final WebSocket socket;
  final DateTime connectedAt;
  Timer? pingTimer;
  Timer? pongTimer;
  bool isAlive = true;
  
  WebSocketConnection({
    required this.id,
    required this.socket,
  }) : connectedAt = DateTime.now();
  
  void dispose() {
    pingTimer?.cancel();
    pongTimer?.cancel();
  }
}

/// WebSocket transport for MCP server
class WebSocketServerTransport implements ServerTransport {
  final WebSocketConfig config;
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  
  HttpServer? _server;
  final Map<String, WebSocketConnection> _connections = {};
  bool _isClosed = false;
  
  WebSocketServerTransport({
    required this.config,
  }) {
    _initialize();
  }
  
  Future<void> _initialize() async {
    try {
      _server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        config.port,
      );
      
      _server!.listen((HttpRequest request) {
        if (request.uri.path == config.path) {
          _handleWebSocketConnection(request);
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..close();
        }
      });
      
      _logger.info('WebSocket server listening on port ${config.port}${config.path}');
    } catch (e) {
      _logger.error('Failed to start WebSocket server: $e');
      _closeCompleter.completeError(e);
    }
  }
  
  Future<void> _handleWebSocketConnection(HttpRequest request) async {
    try {
      final socket = await WebSocketTransformer.upgrade(
        request,
        compression: config.enableCompression 
            ? CompressionOptions.compressionDefault 
            : CompressionOptions.compressionOff,
      );
      
      final connectionId = DateTime.now().millisecondsSinceEpoch.toString();
      final connection = WebSocketConnection(
        id: connectionId,
        socket: socket,
      );
      
      _connections[connectionId] = connection;
      _logger.info('WebSocket client connected: $connectionId');
      
      // Set up ping/pong
      _setupPingPong(connection);
      
      // Listen for messages
      socket.listen(
        (data) => _handleMessage(connectionId, data),
        onError: (error) => _handleError(connectionId, error),
        onDone: () => _handleDisconnect(connectionId),
        cancelOnError: false,
      );
      
    } catch (e) {
      _logger.error('WebSocket upgrade failed: $e');
      request.response
        ..statusCode = HttpStatus.badRequest
        ..close();
    }
  }
  
  void _setupPingPong(WebSocketConnection connection) {
    // Send ping periodically
    connection.pingTimer = Timer.periodic(config.pingInterval, (_) {
      if (!connection.isAlive) {
        _logger.debug('Connection ${connection.id} failed ping/pong check');
        connection.socket.close(WebSocketStatus.goingAway, 'Ping timeout');
        return;
      }
      
      connection.isAlive = false;
      connection.socket.add('ping');
      
      // Set pong timeout
      connection.pongTimer?.cancel();
      connection.pongTimer = Timer(config.pongTimeout, () {
        _logger.debug('Pong timeout for connection ${connection.id}');
        connection.socket.close(WebSocketStatus.goingAway, 'Pong timeout');
      });
    });
  }
  
  void _handleMessage(String connectionId, dynamic data) {
    final connection = _connections[connectionId];
    if (connection == null) return;
    
    // Handle ping/pong
    if (data == 'pong') {
      connection.isAlive = true;
      connection.pongTimer?.cancel();
      return;
    }
    
    if (data == 'ping') {
      connection.socket.add('pong');
      return;
    }
    
    // Handle JSON-RPC messages
    try {
      final message = data is String ? jsonDecode(data) : data;
      if (message is Map && message['jsonrpc'] == '2.0') {
        _messageController.add(message);
      } else {
        _logger.debug('Invalid message from $connectionId: $data');
      }
    } catch (e) {
      _logger.error('Error parsing message from $connectionId: $e');
    }
  }
  
  void _handleError(String connectionId, dynamic error) {
    _logger.error('WebSocket error for $connectionId: $error');
    _removeConnection(connectionId);
  }
  
  void _handleDisconnect(String connectionId) {
    _logger.info('WebSocket client disconnected: $connectionId');
    _removeConnection(connectionId);
  }
  
  void _removeConnection(String connectionId) {
    final connection = _connections.remove(connectionId);
    connection?.dispose();
    
    if (_connections.isEmpty && !_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }
  }
  
  @override
  Stream<dynamic> get onMessage => _messageController.stream;
  
  @override
  Future<void> get onClose => _closeCompleter.future;
  
  @override
  void send(dynamic message) {
    if (_isClosed) return;
    
    final data = jsonEncode(message);
    final toRemove = <String>[];
    
    for (final entry in _connections.entries) {
      try {
        entry.value.socket.add(data);
      } catch (e) {
        _logger.debug('Failed to send to ${entry.key}: $e');
        toRemove.add(entry.key);
      }
    }
    
    for (final id in toRemove) {
      _removeConnection(id);
    }
  }
  
  @override
  void close() {
    if (_isClosed) return;
    _isClosed = true;
    
    // Close all connections
    for (final connection in _connections.values) {
      connection.socket.close();
      connection.dispose();
    }
    _connections.clear();
    
    // Close server
    _server?.close();
    
    // Close controllers
    _messageController.close();
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }
  }
}

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