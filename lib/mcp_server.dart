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

/// Configuration for transport connections
@immutable
sealed class TransportConfig {
  const TransportConfig();

  /// Configuration for STDIO transport
  const factory TransportConfig.stdio() = StdioTransportConfig;

  /// Configuration for SSE transport
  const factory TransportConfig.sse({
    String endpoint,
    String messagesEndpoint,
    String host,
    int port,
    List<int> fallbackPorts,
    String? authToken,
    List<shelf.Middleware> middleware,
  }) = SseTransportConfig;

  /// Configuration for Streamable HTTP transport
  const factory TransportConfig.streamableHttp({
    String host,
    int port,
    String endpoint,
    String messagesEndpoint,
    List<int> fallbackPorts,
    String? authToken,
    bool isJsonResponseEnabled,
    List<shelf.Middleware> middleware,
  }) = StreamableHttpTransportConfig;
}

@immutable
final class StdioTransportConfig extends TransportConfig {
  const StdioTransportConfig();
}

@immutable
final class SseTransportConfig extends TransportConfig {
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

  const SseTransportConfig({
    this.endpoint = '/sse',
    this.messagesEndpoint = '/message',
    this.host = 'localhost',
    this.port = 8080,
    this.fallbackPorts = const [],
    this.authToken,
    this.middleware = const [],
  });
}

@immutable
final class StreamableHttpTransportConfig extends TransportConfig {
  /// The host to bind to
  final String host;

  /// The port to listen on
  final int port;

  /// The endpoint path for HTTP connections
  final String endpoint;

  /// The endpoint path for message sending
  final String messagesEndpoint;

  /// Fallback ports to try if the primary port is unavailable
  final List<int> fallbackPorts;

  /// Authentication token for secure connections
  final String? authToken;

  /// Whether to enable JSON response mode instead of SSE streaming
  final bool isJsonResponseEnabled;

  /// Custom middleware to apply
  final List<shelf.Middleware> middleware;

  const StreamableHttpTransportConfig({
    this.host = 'localhost',
    this.port = 8080,
    this.endpoint = '/messages',
    this.messagesEndpoint = '/message',
    this.fallbackPorts = const [],
    this.authToken,
    this.isJsonResponseEnabled = false,
    this.middleware = const [],
  });
}

// Keep SseServerConfig for backward compatibility
@Deprecated('Use SseTransportConfig instead')
typedef SseServerConfig = SseTransportConfig;


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

  /// Create a stdio transport
  static Result<StdioServerTransport, Exception> createStdioTransport() {
    return Results.catching(() => StdioServerTransport());
  }

  /// Create and start a server using the provided configuration and transport
  static Future<Result<Server, Exception>> createAndStart({
    required McpServerConfig config,
    required TransportConfig transportConfig,
  }) async {
    return Results.catchingAsync(() async {
      final server = createServer(config);
      final transport = await _createTransport(transportConfig);
      server.connect(transport);
      return server;
    });
  }

  /// Create a transport from the given configuration
  static Future<ServerTransport> _createTransport(TransportConfig config) {
    return switch (config) {
      StdioTransportConfig() => Future.value(StdioServerTransport()),
      SseTransportConfig(
        endpoint: final endpoint,
        messagesEndpoint: final messagesEndpoint,
        host: final host,
        port: final port,
        fallbackPorts: final fallbackPorts,
        authToken: final authToken,
      ) =>
        Future.value(SseServerTransport(
          endpoint: endpoint,
          messagesEndpoint: messagesEndpoint,
          host: host,
          port: port,
          fallbackPorts: fallbackPorts,
          authToken: authToken,
        )),
      StreamableHttpTransportConfig(
        host: final host,
        port: final port,
        endpoint: final endpoint,
        messagesEndpoint: final _,
        fallbackPorts: final fallbackPorts,
        authToken: final authToken,
        isJsonResponseEnabled: final isJsonResponseEnabled,
      ) =>
        () async {
          final transport = StreamableHttpServerTransport(
            config: StreamableHttpServerConfig(
              host: host,
              port: port,
              endpoint: endpoint,
              fallbackPorts: fallbackPorts,
              isJsonResponseEnabled: isJsonResponseEnabled,
              authToken: authToken,
            ),
          );
          await transport.start();
          return transport;
        }(),
    };
  }

  /// Create a transport using unified configuration (Result-based)
  static Result<Future<ServerTransport>, Exception> createTransport(
    TransportConfig config,
  ) {
    return Results.catching(() => _createTransport(config));
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
      capabilities: ServerCapabilities.simple(
        tools: true,
        resources: true,
        prompts: true,
      ),
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
      capabilities: capabilities ?? ServerCapabilities.simple(
        tools: true,
        toolsListChanged: true,
        resources: true,
        resourcesListChanged: true,
        prompts: true,
        promptsListChanged: true,
        logging: true,
        progress: true,
      ),
      enableDebugLogging: false,
      maxConnections: 1000,
      requestTimeout: const Duration(seconds: 60),
      enableMetrics: true,
    );
  }

  /// Create an SSE transport with the given configuration
  @Deprecated('Use createTransport(TransportConfig.sse(...)) instead')
  static Result<SseServerTransport, Exception> createSseTransport(
    SseTransportConfig config,
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
    String? authToken,
  }) async {
    try {
      final transport = StreamableHttpServerTransport(
        config: StreamableHttpServerConfig(
          endpoint: endpoint,
          port: port,
          host: host,
          fallbackPorts: fallbackPorts ?? [port + 1, port + 2, port + 3],
          isJsonResponseEnabled: isJsonResponseEnabled,
          authToken: authToken,
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
    String? authToken,
  }) {
    return Results.catching(() {
      final transport = StreamableHttpServerTransport(
        config: StreamableHttpServerConfig(
          endpoint: endpoint,
          port: port,
          host: host,
          fallbackPorts: fallbackPorts ?? [port + 1, port + 2, port + 3],
          isJsonResponseEnabled: isJsonResponseEnabled,
          authToken: authToken,
        ),
        sessionId: sessionId,
      );
      return transport;
    });
  }

}