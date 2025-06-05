import 'package:meta/meta.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'src/server/server.dart';
import 'src/transport/transport.dart';
import 'src/protocol/capabilities.dart';
import 'src/common/result.dart';

export 'src/models/models.dart';
export 'src/server/server.dart';
export 'src/transport/transport.dart';
export 'src/protocol/protocol.dart';
export 'src/protocol/capabilities.dart';
export 'src/annotations/tool_annotations.dart';
export 'src/auth/auth_middleware.dart';
export 'src/common/result.dart';
export 'logger.dart';

/// Configuration for creating MCP servers
@immutable
class McpServerConfig {
  /// The name of the server application
  final String name;

  /// The version of the server application
  final String version;

  /// The capabilities supported by the server
  final ServerCapabilities capabilities;

  /// Whether to enable debug logging
  final bool enableDebugLogging;

  /// Maximum number of concurrent connections
  final int maxConnections;

  /// Timeout for client requests
  final Duration requestTimeout;

  /// Whether to enable performance metrics
  final bool enableMetrics;

  const McpServerConfig({
    required this.name,
    required this.version,
    this.capabilities = const ServerCapabilities(),
    this.enableDebugLogging = false,
    this.maxConnections = 100,
    this.requestTimeout = const Duration(seconds: 30),
    this.enableMetrics = false,
  });

  /// Creates a copy of this config with the given fields replaced
  McpServerConfig copyWith({
    String? name,
    String? version,
    ServerCapabilities? capabilities,
    bool? enableDebugLogging,
    int? maxConnections,
    Duration? requestTimeout,
    bool? enableMetrics,
  }) {
    return McpServerConfig(
      name: name ?? this.name,
      version: version ?? this.version,
      capabilities: capabilities ?? this.capabilities,
      enableDebugLogging: enableDebugLogging ?? this.enableDebugLogging,
      maxConnections: maxConnections ?? this.maxConnections,
      requestTimeout: requestTimeout ?? this.requestTimeout,
      enableMetrics: enableMetrics ?? this.enableMetrics,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is McpServerConfig &&
      name == other.name &&
      version == other.version &&
      capabilities == other.capabilities &&
      enableDebugLogging == other.enableDebugLogging &&
      maxConnections == other.maxConnections &&
      requestTimeout == other.requestTimeout &&
      enableMetrics == other.enableMetrics;

  @override
  int get hashCode => Object.hash(
    name,
    version,
    capabilities,
    enableDebugLogging,
    maxConnections,
    requestTimeout,
    enableMetrics,
  );

  @override
  String toString() => 'McpServerConfig('
      'name: $name, '
      'version: $version, '
      'capabilities: $capabilities, '
      'enableDebugLogging: $enableDebugLogging, '
      'maxConnections: $maxConnections, '
      'requestTimeout: $requestTimeout, '
      'enableMetrics: $enableMetrics)';
}

/// Configuration for SSE transport
@immutable
class SseServerConfig {
  /// The endpoint path for SSE connections
  final String endpoint;

  /// The endpoint path for message sending
  final String messagesEndpoint;

  /// The host to bind to
  final String host;

  /// The port to listen on
  final int port;

  /// Fallback ports to try if the primary port is unavailable
  final List<int> fallbackPorts;

  /// Authentication token for secure connections
  final String? authToken;


  /// Custom middleware to apply
  final List<shelf.Middleware> middleware;

  const SseServerConfig({
    this.endpoint = '/sse',
    this.messagesEndpoint = '/messages',
    this.host = 'localhost',
    this.port = 8080,
    this.fallbackPorts = const [],
    this.authToken,
    this.middleware = const [],
  });

  /// Creates a copy of this config with the given fields replaced
  SseServerConfig copyWith({
    String? endpoint,
    String? messagesEndpoint,
    String? host,
    int? port,
    List<int>? fallbackPorts,
    String? authToken,
    List<shelf.Middleware>? middleware,
  }) {
    return SseServerConfig(
      endpoint: endpoint ?? this.endpoint,
      messagesEndpoint: messagesEndpoint ?? this.messagesEndpoint,
      host: host ?? this.host,
      port: port ?? this.port,
      fallbackPorts: fallbackPorts ?? this.fallbackPorts,
      authToken: authToken ?? this.authToken,
      middleware: middleware ?? this.middleware,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SseServerConfig &&
      endpoint == other.endpoint &&
      messagesEndpoint == other.messagesEndpoint &&
      host == other.host &&
      port == other.port &&
      _listEquals(fallbackPorts, other.fallbackPorts) &&
      authToken == other.authToken &&
      _listEquals(middleware, other.middleware);

  @override
  int get hashCode => Object.hash(
    endpoint,
    messagesEndpoint,
    host,
    port,
    fallbackPorts,
    authToken,
    middleware,
  );

  @override
  String toString() => 'SseServerConfig('
      'endpoint: $endpoint, '
      'messagesEndpoint: $messagesEndpoint, '
      'host: $host, '
      'port: $port, '
      'fallbackPorts: $fallbackPorts, '
      'authToken: ${authToken != null ? '[REDACTED]' : 'null'}, '
      'middleware: ${middleware.length} items)';
}

typedef MCPServer = McpServer;

/// Modern MCP Server factory with enhanced configuration and error handling
@immutable
class McpServer {
  const McpServer._();

  /// Create a new MCP server with the specified configuration
  static Server createServer(McpServerConfig config) {
    if (config.enableDebugLogging) {
      Logger.root.level = Level.FINE;
    }

    return Server(
      name: config.name,
      version: config.version,
      capabilities: config.capabilities,
    );
  }

  /// Create and start a server with the given configuration and transport
  static Future<Result<Server, Exception>> createAndStart({
    required McpServerConfig config,
    required ServerTransport transport,
  }) async {
    return Results.catchingAsync(() async {
      final server = createServer(config);
      server.connect(transport);
      return server;
    });
  }

  /// Create a stdio transport
  static Result<StdioServerTransport, Exception> createStdioTransport() {
    return Results.catching(() => StdioServerTransport());
  }

  /// Create an SSE transport with the given configuration
  static Result<SseServerTransport, Exception> createSseTransport(
    SseServerConfig config,
  ) {
    return Results.catching(() => SseServerTransport(
      endpoint: config.endpoint,
      messagesEndpoint: config.messagesEndpoint,
      host: config.host,
      port: config.port,
      fallbackPorts: config.fallbackPorts,
      authToken: config.authToken,
    ));
  }


  /// Create a StreamableHTTP transport with the given configuration
  static Future<Result<StreamableHttpServerTransport, Exception>> createStreamableHttpTransportAsync(
    int port, {
    String endpoint = '/mcp',
    String host = 'localhost',
    List<int>? fallbackPorts,
    bool isJsonResponseEnabled = false,
    String? sessionId,
  }) async {
    try {
      final transport = StreamableHttpServerTransport(
        config: StreamableHttpServerConfig(
          endpoint: endpoint,
          port: port,
          host: host,
          fallbackPorts: fallbackPorts ?? [port + 1, port + 2, port + 3],
          isJsonResponseEnabled: isJsonResponseEnabled,
        ),
        sessionId: sessionId,
      );
      // Start the server and wait for it to be ready
      await transport.start();
      return Result.success(transport);
    } catch (e) {
      return Result.failure(Exception('Failed to create StreamableHTTP transport: $e'));
    }
  }

  /// Create a StreamableHTTP transport with the given configuration (sync version)
  static Result<StreamableHttpServerTransport, Exception> createStreamableHttpTransport(
    int port, {
    String endpoint = '/mcp',
    String host = 'localhost',
    List<int>? fallbackPorts,
    bool isJsonResponseEnabled = false,
    String? sessionId,
  }) {
    return Results.catching(() {
      final transport = StreamableHttpServerTransport(
        config: StreamableHttpServerConfig(
          endpoint: endpoint,
          port: port,
          host: host,
          fallbackPorts: fallbackPorts ?? [port + 1, port + 2, port + 3],
          isJsonResponseEnabled: isJsonResponseEnabled,
        ),
        sessionId: sessionId,
      );
      return transport;
    });
  }

  /// Helper method to create a simple server configuration
  static McpServerConfig simpleConfig({
    required String name,
    required String version,
    bool enableDebugLogging = false,
  }) {
    return McpServerConfig(
      name: name,
      version: version,
      enableDebugLogging: enableDebugLogging,
    );
  }

  /// Helper method to create a production-ready server configuration
  static McpServerConfig productionConfig({
    required String name,
    required String version,
    ServerCapabilities? capabilities,
  }) {
    return McpServerConfig(
      name: name,
      version: version,
      capabilities: capabilities ?? const ServerCapabilities(),
      enableDebugLogging: false,
      maxConnections: 1000,
      requestTimeout: const Duration(seconds: 60),
      enableMetrics: true,
    );
  }

  /// Helper method to create a simple SSE server configuration
  static SseServerConfig simpleSseConfig({
    int port = 8080,
    String? authToken,
  }) {
    return SseServerConfig(
      port: port,
      authToken: authToken,
    );
  }

  /// Helper method to create a production-ready SSE server configuration
  static SseServerConfig productionSseConfig({
    int port = 8080,
    List<int> fallbackPorts = const [8081, 8082, 8083],
    required String authToken,
  }) {
    return SseServerConfig(
      port: port,
      fallbackPorts: fallbackPorts,
      authToken: authToken,
      middleware: [
        shelf.logRequests(),
      ],
    );
  }
}

/// Helper function to compare lists for equality
bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}