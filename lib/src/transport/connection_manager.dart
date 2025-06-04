/// Connection retry and management for MCP transport
library;

import 'dart:async';
import 'dart:math' as math;

import '../../logger.dart';

final Logger _logger = Logger('mcp_server.connection_manager');

/// Retry configuration
class RetryConfig {
  /// Initial delay before first retry
  final Duration initialDelay;
  
  /// Maximum delay between retries
  final Duration maxDelay;
  
  /// Exponential backoff factor
  final double backoffFactor;
  
  /// Maximum number of retry attempts (-1 for infinite)
  final int maxAttempts;
  
  /// Jitter factor (0-1) to randomize delays
  final double jitterFactor;
  
  const RetryConfig({
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(minutes: 5),
    this.backoffFactor = 2.0,
    this.maxAttempts = -1,
    this.jitterFactor = 0.1,
  });
  
  /// Default retry configuration
  static const RetryConfig defaultConfig = RetryConfig();
  
  /// Aggressive retry for critical connections
  static const RetryConfig aggressive = RetryConfig(
    initialDelay: Duration(milliseconds: 100),
    maxDelay: Duration(seconds: 30),
    backoffFactor: 1.5,
  );
  
  /// Conservative retry for non-critical connections
  static const RetryConfig conservative = RetryConfig(
    initialDelay: Duration(seconds: 5),
    maxDelay: Duration(minutes: 10),
    backoffFactor: 3.0,
    maxAttempts: 10,
  );
}

/// Connection state
enum ConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed,
}

/// Connection manager with retry logic
class ConnectionManager<T> {
  final String name;
  final Future<T> Function() connectFunction;
  final void Function(T) onConnected;
  final void Function(dynamic) onError;
  final RetryConfig config;
  
  final _stateController = StreamController<ConnectionState>.broadcast();
  final _random = math.Random();
  
  ConnectionState _state = ConnectionState.disconnected;
  Timer? _retryTimer;
  int _attemptCount = 0;
  Duration _currentDelay;
  T? _connection;
  bool _disposed = false;
  
  ConnectionManager({
    required this.name,
    required this.connectFunction,
    required this.onConnected,
    required this.onError,
    RetryConfig? config,
  }) : config = config ?? RetryConfig.defaultConfig,
       _currentDelay = config?.initialDelay ?? RetryConfig.defaultConfig.initialDelay;
  
  /// Current connection state
  ConnectionState get state => _state;
  
  /// Stream of state changes
  Stream<ConnectionState> get stateStream => _stateController.stream;
  
  /// Current connection
  T? get connection => _connection;
  
  /// Whether connected
  bool get isConnected => _state == ConnectionState.connected;
  
  /// Start connection with retry
  Future<void> connect() async {
    if (_disposed) {
      throw StateError('ConnectionManager has been disposed');
    }
    
    if (_state == ConnectionState.connecting || 
        _state == ConnectionState.connected) {
      return;
    }
    
    _attemptCount = 0;
    _currentDelay = config.initialDelay;
    await _tryConnect();
  }
  
  /// Disconnect without retry
  void disconnect() {
    _retryTimer?.cancel();
    _connection = null;
    _setState(ConnectionState.disconnected);
  }
  
  /// Reconnect (force new connection)
  Future<void> reconnect() async {
    disconnect();
    await connect();
  }
  
  Future<void> _tryConnect() async {
    if (_disposed) return;
    
    _setState(ConnectionState.connecting);
    _attemptCount++;
    
    try {
      _logger.info('[$name] Connection attempt #$_attemptCount');
      _connection = await connectFunction();
      
      if (_disposed) {
        // Disposed during connection
        return;
      }
      
      _setState(ConnectionState.connected);
      _attemptCount = 0;
      _currentDelay = config.initialDelay;
      
      final conn = _connection;
      if (conn != null) {
        onConnected(conn);
      }
      _logger.info('[$name] Connected successfully');
      
    } catch (e) {
      _logger.error('[$name] Connection failed: $e');
      onError(e);
      
      if (_disposed) return;
      
      // Check if we should retry
      if (config.maxAttempts > 0 && _attemptCount >= config.maxAttempts) {
        _logger.error('[$name] Max retry attempts reached');
        _setState(ConnectionState.failed);
        return;
      }
      
      // Schedule retry with backoff
      _setState(ConnectionState.reconnecting);
      final delay = _calculateDelay();
      _logger.info('[$name] Retrying in ${delay.inSeconds} seconds');
      
      _retryTimer?.cancel();
      _retryTimer = Timer(delay, () {
        if (!_disposed) {
          _tryConnect();
        }
      });
    }
  }
  
  Duration _calculateDelay() {
    // Calculate exponential backoff
    var delay = _currentDelay.inMilliseconds * config.backoffFactor;
    
    // Apply max delay cap
    delay = math.min(delay, config.maxDelay.inMilliseconds.toDouble());
    
    // Apply jitter
    if (config.jitterFactor > 0) {
      final jitter = delay * config.jitterFactor;
      final randomJitter = _random.nextDouble() * jitter * 2 - jitter;
      delay += randomJitter;
    }
    
    _currentDelay = Duration(milliseconds: delay.round());
    return _currentDelay;
  }
  
  void _setState(ConnectionState newState) {
    if (_state != newState) {
      _state = newState;
      if (!_stateController.isClosed) {
        _stateController.add(newState);
      }
    }
  }
  
  /// Dispose the connection manager
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _connection = null;
    _stateController.close();
  }
}

/// Connection pool for managing multiple connections
class ConnectionPool<T> {
  final String name;
  final int maxConnections;
  final Future<T> Function() connectionFactory;
  final RetryConfig? retryConfig;
  
  final List<ConnectionManager<T>> _managers = [];
  final List<T> _availableConnections = [];
  final _connectionRequests = <Completer<T>>[];
  
  ConnectionPool({
    required this.name,
    required this.maxConnections,
    required this.connectionFactory,
    this.retryConfig,
  });
  
  /// Get a connection from the pool
  Future<T> acquire() async {
    // Check for available connection
    if (_availableConnections.isNotEmpty) {
      return _availableConnections.removeLast();
    }
    
    // Create new connection if under limit
    if (_managers.length < maxConnections) {
      final manager = ConnectionManager<T>(
        name: '$name-${_managers.length}',
        connectFunction: connectionFactory,
        onConnected: (connection) {
          // Connection established, fulfill pending request
          if (_connectionRequests.isNotEmpty) {
            final request = _connectionRequests.removeAt(0);
            request.complete(connection);
          } else {
            _availableConnections.add(connection);
          }
        },
        onError: (error) {
          _logger.error('Connection pool error: $error');
        },
        config: retryConfig,
      );
      
      _managers.add(manager);
      await manager.connect();
    }
    
    // Wait for available connection
    final completer = Completer<T>();
    _connectionRequests.add(completer);
    return completer.future;
  }
  
  /// Release a connection back to the pool
  void release(T connection) {
    if (_connectionRequests.isNotEmpty) {
      final request = _connectionRequests.removeAt(0);
      request.complete(connection);
    } else {
      _availableConnections.add(connection);
    }
  }
  
  /// Close all connections
  void close() {
    for (final manager in _managers) {
      manager.dispose();
    }
    _managers.clear();
    _availableConnections.clear();
    
    // Cancel pending requests
    for (final request in _connectionRequests) {
      request.completeError('Connection pool closed');
    }
    _connectionRequests.clear();
  }
}