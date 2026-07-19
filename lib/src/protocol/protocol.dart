import 'package:meta/meta.dart';

/// MCP Protocol Version constants and definitions
@immutable
class McpProtocol {
  // JSON-RPC version
  static const String jsonRpcVersion = "2.0";
  
  // Protocol versions
  static const String v2024_11_05 = "2024-11-05";
  static const String v2025_03_26 = "2025-03-26";
  static const String v2025_06_18 = "2025-06-18";
  static const String v2025_11_25 = "2025-11-25";
  static const String latest = v2025_11_25;

  /// Protocol version 2026-07-28 — BREAKING: stateless core (removes the
  /// `initialize`/`initialized` handshake and `Mcp-Session-Id`; client
  /// info/caps ride `_meta` on every request; `server/discover` fetches
  /// caps on demand), Extensions framework, Tasks extension, auth
  /// hardening, deprecations. Adopted as an additive, version-gated
  /// parallel path — the handshake path stays for ≤2025-11-25 peers.
  /// Deliberately NOT in [supportedVersions] until the stateless request
  /// path lands, so handshake negotiation does not advertise it yet.
  /// See `docs/STATELESS-COEXISTENCE-DESIGN.md`.
  static const String v2026_07_28 = "2026-07-28";

  /// Whether the [version] uses the stateless core (no handshake/session):
  /// client info/caps in `_meta` per request, `server/discover` for caps,
  /// `MCP-Protocol-Version` the sole version signal. Introduced 2026-07-28.
  static bool isStateless(String version) => version == v2026_07_28;

  /// All supported versions in order of preference (newest first).
  ///
  /// `v2026_07_28` is intentionally NOT listed yet (declared but its
  /// stateless request path is unimplemented) — the server must not
  /// advertise it in handshake negotiation until that lands.
  static const List<String> supportedVersions = [
    v2025_11_25,
    v2025_06_18,
    v2025_03_26,
    v2024_11_05,
  ];

  /// Date-ordered comparison of two revision strings (`YYYY-MM-DD`): true when
  /// [version] is the same date as, or newer than, [floor].
  ///
  /// Used so a feature *introduced at* [floor] stays enabled for every LATER
  /// revision (MCP is cumulative — new revisions coexist with and extend older
  /// ones, they do not revert them). Writing these gates as `== <exact>` would
  /// silently turn the feature OFF for the next revision (e.g. 2026-07-28),
  /// forward-regressing SEP-1303 / SEP-1613 / elicitation / structured output.
  static bool _isAtLeast(String version, String floor) {
    final v = DateTime.tryParse(version);
    final f = DateTime.tryParse(floor);
    if (v == null || f == null) return false;
    return !v.isBefore(f);
  }

  /// Whether the negotiated [version] supports JSON-RPC batching.
  /// A bounded legacy set — batching was *removed* in 2025-06-18 (PR #416),
  /// so this is intentionally not an "at least" gate.
  static bool supportsBatching(String version) =>
      version == v2024_11_05 || version == v2025_03_26;

  /// Whether the negotiated [version] knows the `elicitation/create`
  /// server → client request (introduced in 2025-06-18, carried forward).
  static bool supportsElicitation(String version) =>
      _isAtLeast(version, v2025_06_18);

  /// Whether the negotiated [version] understands the `MCP-Protocol-Version`
  /// HTTP header (mandatory after negotiation from 2025-06-18 onwards).
  static bool requiresProtocolHeader(String version) =>
      _isAtLeast(version, v2025_06_18);

  /// Whether tool execution errors are returned as an `isError`
  /// [CallToolResult] (so the model can self-correct) rather than a
  /// JSON-RPC protocol error. Clarified in 2025-11-25 (SEP-1303) and carried
  /// forward. Older negotiated versions keep the prior protocol-error behavior.
  static bool toolErrorsAsResult(String version) =>
      _isAtLeast(version, v2025_11_25);

  /// Whether the negotiated [version] understands `Tool.outputSchema`,
  /// `CallToolResult.structuredContent`, and `resource_link` content
  /// (introduced in 2025-06-18, carried forward).
  static bool supportsStructuredToolOutput(String version) =>
      _isAtLeast(version, v2025_06_18);

  /// Whether the negotiated [version] understands `Tool.icons`,
  /// sampling `tools` / `toolChoice`, and URL-mode elicitation
  /// (introduced in 2025-11-25, carried forward).
  static bool supportsIconsAndSamplingTools(String version) =>
      _isAtLeast(version, v2025_11_25);

  /// Canonical URI of the JSON Schema 2020-12 dialect — the default dialect
  /// for tool `inputSchema` / `outputSchema` as of 2025-11-25 (SEP-1613).
  static const String jsonSchemaDialect2020_12 =
      'https://json-schema.org/draft/2020-12/schema';

  /// Whether tool schemas emitted to the negotiated [version] should carry
  /// an explicit `$schema: <2020-12>` default annotation (SEP-1613).
  /// Applied for 2025-11-25 and later peers; older peers keep prior output.
  static bool defaultsJsonSchemaDialect(String version) =>
      _isAtLeast(version, v2025_11_25);

  /// Returns a copy of [schema] annotated with the default JSON Schema
  /// 2020-12 dialect (`$schema`) when it is an object-type schema that does
  /// not already declare a `$schema`. Free-form schemas that already carry
  /// a `$schema`, or non-object schema fragments, are returned unchanged.
  static Map<String, dynamic> withDefaultSchemaDialect(
      Map<String, dynamic> schema) {
    if (schema.containsKey(r'$schema')) return schema;
    return {r'$schema': jsonSchemaDialect2020_12, ...schema};
  }
  
  // Method names (aliases for compatibility)
  static const String methodInitialize = 'initialize';
  static const String methodInitialized = 'notifications/initialized';
  static const String methodListTools = 'tools/list';
  static const String methodCallTool = 'tools/call';
  static const String methodListResources = 'resources/list';
  static const String methodReadResource = 'resources/read';
  static const String methodListPrompts = 'prompts/list';
  static const String methodGetPrompt = 'prompts/get';
  static const String methodComplete = 'completion/complete';
  
  // Error codes (aliases)
  static const int errorMethodNotFound = -32601;
  
  /// Check if a version is supported
  static bool isSupported(String version) => supportedVersions.contains(version);
  
  /// Get the highest compatible version between client and server
  static String? negotiate(List<String> clientVersions, List<String> serverVersions) {
    for (final serverVersion in serverVersions) {
      if (clientVersions.contains(serverVersion)) {
        return serverVersion;
      }
    }
    return null;
  }

  /// Advanced version negotiation with date-based compatibility
  static String? negotiateWithDateFallback(String? clientVersion, List<String> serverVersions) {
    if (clientVersion == null) {
      // Client didn't specify version, use latest
      return serverVersions.first;
    } 
    
    if (serverVersions.contains(clientVersion)) {
      // Exact match
      return clientVersion;
    }
    
    // Try date-based compatibility
    try {
      final clientDate = DateTime.parse(clientVersion);
      
      // Find server versions that are equal or older than client version
      final compatibleVersions = serverVersions
          .map((v) => DateTime.tryParse(v))
          .where((d) => d != null && d.compareTo(clientDate) <= 0)
          .cast<DateTime>()
          .toList();
      
      if (compatibleVersions.isNotEmpty) {
        // Sort in descending order and take newest compatible
        compatibleVersions.sort((a, b) => b.compareTo(a));
        final index = serverVersions.indexWhere(
          (v) => DateTime.tryParse(v)?.isAtSameMomentAs(compatibleVersions.first) ?? false
        );
        return index >= 0 ? serverVersions[index] : null;
      }
    } catch (e) {
      // Invalid date format, fall back to null
    }
    
    return null;
  }
}

/// Standard MCP methods that must be implemented
@immutable
class McpMethods {
  // Core protocol methods
  static const String initialize = 'initialize';
  static const String ping = 'ping';
  static const String shutdown = 'shutdown';
  
  // Tool methods
  static const String listTools = 'tools/list';
  static const String callTool = 'tools/call';
  
  // Resource methods
  static const String listResources = 'resources/list';
  static const String readResource = 'resources/read';
  static const String subscribeResource = 'resources/subscribe';
  static const String unsubscribeResource = 'resources/unsubscribe';
  static const String listResourceTemplates = 'resources/templates/list';
  
  // Prompt methods
  static const String listPrompts = 'prompts/list';
  static const String getPrompt = 'prompts/get';
  
  // Logging methods
  static const String setLoggingLevel = 'logging/setLevel';
  
  // Sampling methods
  static const String createMessage = 'sampling/createMessage';
  
  // Roots methods
  static const String listRoots = 'roots/list';
  
  // Completion methods
  static const String completeArgument = 'completion/complete';
  
  // Notification methods
  static const String notificationCancelled = 'notifications/cancelled';
  static const String notificationProgress = 'notifications/progress';
  static const String notificationResourcesListChanged = 'notifications/resources/list_changed';
  static const String notificationToolsListChanged = 'notifications/tools/list_changed';
  static const String notificationPromptsListChanged = 'notifications/prompts/list_changed';
  static const String notificationRootsListChanged = 'notifications/roots/list_changed';
  static const String notificationMessage = 'notifications/message';
}

/// MCP Error codes as defined in the specification
@immutable
class McpErrorCodes {
  // JSON-RPC 2.0 standard errors
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;
  
  // MCP-specific errors
  static const int toolNotFound = -32000;
  static const int resourceNotFound = -32001;
  static const int promptNotFound = -32002;
  static const int cancelled = -32003;
  static const int timeout = -32004;
  static const int permissionDenied = -32005;
  static const int rateLimited = -32006;
  static const int networkError = -32007;
  static const int protocolError = -32008;
  
  /// Get error message for code
  static String getMessage(int code) {
    return switch (code) {
      parseError => 'Parse error',
      invalidRequest => 'Invalid request',
      methodNotFound => 'Method not found',
      invalidParams => 'Invalid params',
      internalError => 'Internal error',
      toolNotFound => 'Tool not found',
      resourceNotFound => 'Resource not found',
      promptNotFound => 'Prompt not found',
      cancelled => 'Operation cancelled',
      timeout => 'Operation timeout',
      permissionDenied => 'Permission denied',
      rateLimited => 'Rate limited',
      networkError => 'Network error',
      protocolError => 'Protocol error',
      _ => 'Unknown error',
    };
  }
}