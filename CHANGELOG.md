## [2.0.0] - upcoming - MCP spec compliance + 2025-11-25 alignment

Big-Bang spec normalization. Supports protocol revisions 2024-11-05, 2025-03-26, 2025-06-18, and 2025-11-25 with per-version capability gating.

### Breaking
- **Sampling direction fixed.** Server now initiates `sampling/createMessage` outbound to the client (per spec). The previous inbound handler (broken — it forwarded the request back to the client through a notification) is removed. Use `Server.requestClientSampling(sessionId, params)` from tool handlers.
- **Roots direction fixed.** Server requests roots from the client via `Server.requestClientRoots(sessionId)`. The spurious server-side `notifications/roots/list_changed` broadcasts in `addRoot` / `removeRoot` are removed; that notification is client → server only per spec.
- **`list_changed` notifications use the standard names.** `tools/listChanged` → `notifications/tools/list_changed`; same for resources and prompts. Existing clients that listened on the legacy names will not see updates.
- **Non-standard JSON-RPC methods removed.** `cancel` (request) is replaced by `notifications/cancelled` (notification). `client/ready`, `health/check`, `sampling/response`, and `auth/authorize` / `auth/token` / `auth/refresh` / `auth/revoke` are deleted. OAuth is now an HTTP-layer Resource Server (RFC 9728) — see `Server.configureProtectedResource`.
- **JSON-RPC batching removed for 2025-06-18+.** `BatchRequestTracker` and the `batchId` field are deleted. Batching still works for sessions that negotiate 2024-11-05 or 2025-03-26.

### Added
- `Server.requestClientSampling`, `requestClientRoots`, `requestClientElicitation` — server-initiated outbound requests with response routing and timeout.
- `Server.addCompletion` / `removeCompletion` — handler registration for the standard `completion/complete` request, with the new 2025-06-18 `context` field for previously-resolved arguments.
- Incoming handlers for `notifications/cancelled` and `notifications/progress` (client → server).
- `CompletionsCapability` advertised via `ServerCapabilities`.
- `Tool.outputSchema`, `Tool.title`, `Tool.icons`, `Tool.meta` (spec 2025-06-18 / 2025-11-25 metadata).
- `CallToolResult.structuredContent` (spec 2025-06-18 structured tool output).
- `ResourceLinkContent` (spec 2025-06-18 `resource_link` content type) and `AudioContent` (2025-03-26+).
- `Resource.title` / `Prompt.title` / `ResourceTemplate.title` plus matching `icons` / `_meta` fields.
- `Server.configureProtectedResource` and `Server.protectedResourceMetadata` — RFC 9728 OAuth Protected Resource metadata for `.well-known/oauth-protected-resource`.
- `Server.onClientProgress` — listener for inbound progress notifications.
- `McpProtocol.v2025_06_18` and `McpProtocol.v2025_11_25` constants. `latest` advances to `v2025_11_25`.
- `McpProtocol.supportsBatching` / `supportsElicitation` / `requiresProtocolHeader` / `supportsStructuredToolOutput` / `supportsIconsAndSamplingTools` per-version gates.

### Removed
- `McpServer.cancel` request handler and the `_handleCancelOperation` method.
- `McpServer.health/check` and the `_handleHealthCheck` method.
- All JSON-RPC `auth/*` request handlers and the OAuth grant helpers (~350 lines).
- `BatchRequestTracker` and batch-array dispatch (replaced with single-message dispatch on 2025-06-18+).

---

## [1.0.5] - 2026-04-30

- Resource read cache is now opt-in. Pass `cacheable: true` (and optional `cache_max_age`) to cache a response. Mutable resources are no longer silently served stale.

---

## [1.0.4] - 2026-04-28

### Changed
- README cleanup — removed "MCP Family" section, installation block, dev.to articles, and donation links.

---

## 1.0.3

### Bug Fixes
- **StreamableHTTP MCP 2025-03-26 Compliance**
  - Fixed POST SSE stream closure: now closes immediately after sending response per spec
  - Added `enableGetStream` config option for optional GET stream support (default: true)
  - GET stream properly returns 405 Method Not Allowed when disabled
  - Ensures notifications use appropriate stream channels per MCP standard
  - Fixed 409 Conflict error: GET streams now managed per-session

## 1.0.2 

### 🔒 Security Enhancements
- **CRITICAL**: Fixed StreamableHTTP transport authentication vulnerability
- Added Bearer token validation to StreamableHTTP transport (consistent with SSE)
- Implemented comprehensive authentication for all HTTP methods (POST, GET, DELETE)
- Enhanced factory methods to support `authToken` parameter
- Added authentication compliance tests for MCP security standards

### Features
- Added `authToken` parameter to `StreamableHttpServerConfig`
- Enhanced unified API with `authToken` support in `TransportConfig.streamableHttp()`
- Improved error messages for authentication failures
- Added comprehensive authentication test suite

### Bug Fixes
- Fixed MCP standard compliance issue where StreamableHTTP lacked authentication
- Resolved security inconsistency between SSE and StreamableHTTP transports

### Tests
- Added `streamable_http_authentication_test.dart` with comprehensive auth coverage
- Consolidated and cleaned up duplicate test files
- Enhanced test documentation in `test/README.md`

## 1.0.1 

### Bug Fixes
- Fixed resource update notification format mismatch with client expectations
- Made resource content optional in notifications for MCP 2025-03-26 compliance
- Enhanced `notifyResourceUpdated` method to support both standard (URI-only) and extended (with content) notification formats

## 1.0.0 - 2025-03-26

### 🎉 Major Release - MCP Protocol v2025-03-26

#### Added
- **MCP Protocol v2025-03-26 Support**
  - Full compliance with latest MCP specification
  - Enhanced JSON-RPC 2.0 implementation
  - Backward compatibility with 2024-11-05
  - Protocol version negotiation

- **Modern Dart Patterns**
  - Result<T, E> pattern for error handling
  - Sealed classes for type safety
  - Pattern matching with switch expressions
  - Immutable data structures with @immutable

- **Enhanced Tool System**
  - Tool annotations for metadata and capabilities
  - ToolAnnotationUtils builder for easy configuration
  - Support for progress tracking and cancellation
  - Tool categories and priorities
  - Estimated duration and examples

- **OAuth 2.1 Authentication**
  - Built-in OAuth middleware support
  - Token validation and refresh
  - Scope-based authorization
  - Session management integration

- **Streamable HTTP Transport**
  - HTTP/2 support for better performance
  - Concurrent request handling
  - Keep-alive connections
  - Enhanced CORS configuration

- **Advanced Configuration System**
  - McpServerConfig for type-safe setup
  - Production-ready defaults
  - Environment-based configuration
  - Feature flags support

- **Connection State Management**
  - Real-time connection monitoring
  - Automatic client recovery
  - Health check endpoints
  - Circuit breaker patterns

- **Standard Logging Integration**
  - package:logging based system
  - Colored terminal output
  - Structured log formatting
  - Performance metrics tracking

#### Changed
- **Breaking Changes**
  - Upgraded minimum Dart SDK to ^3.8.0
  - New factory-based server creation
  - Enhanced configuration patterns
  - Improved type safety throughout

- **API Improvements**
  - Simplified server creation with McpServer.createAndStart()
  - Better transport configuration
  - More intuitive error handling
  - Enhanced capability declarations

#### Protocol Compliance
- ✅ JSON-RPC 2.0 specification
- ✅ MCP Core Protocol v2025-03-26
- ✅ Bidirectional communication
- ✅ Tool execution with progress
- ✅ Resource management with templates
- ✅ Prompt handling with metadata
- ✅ Sampling (LLM text generation)
- ✅ Logging integration
- ✅ Root management
- ✅ Progress notifications
- ✅ Cancellation support
- ✅ Batch operations

## 0.2.0
## 0.1.9

* Added
  * Session event monitoring system using Dart's Stream API
    * `onConnect` stream for client connection events
    * `onDisconnect` stream for client disconnection events
  * Real-time client connection and disconnection tracking
  * Session-specific initialization and cleanup automation
  * Server resource disposal improvements

## 0.1.8
## 0.1.7
## 0.1.6
## 0.1.5

* Bug Fixed

## 0.1.4
## 0.1.3
## 0.1.2

* Added
  * Full implementation of MCP protocol 2024-11-05
  * Sampling support with client request forwarding
  * Roots management for filesystem boundary control
  * Resource subscription system with updates notification
  * Resource caching mechanism for performance optimization
  * Operation cancellation support
  * Progress reporting for long-running operations
* Fixed
  * Protocol version negotiation now properly supports multiple versions
  * Type inconsistencies in model classes and JSON conversions
  * Ensured capabilities are properly exposed based on server configuration
* Improved
  * Error handling with standardized error codes
  * Session management for multiple client connections
  * server health monitoring and metrics tracking
  * Transport implementation with better CORS support
  * Added options to colorize logs and include timestamps for easier debugging

## 0.1.1

* SSE Endpoint Improvements
  * Added compatibility with MCP Inspector by sending initial SSE event in event: endpoint format
  * Ensured event: message usage for subsequent JSON-RPC data
* Logging and Debug Enhancements
  * Introduced optional debug function with adjustable log level
  * Removed excessive stderr.writeln calls, improving performance and clarity
* Authorization Logic Updates
  * Allows optional token-based authentication for SSE connections
  * Maintains session-based approach to restrict message endpoint usage
* Bug Fixes
  * Resolved SSE Body Timeout Error by flushing initial messages immediately
  * Ensured consistent CORS and OPTIONS handling for cross-origin requests
* Refactoring
  * Cleaned up code structure for better maintainability
  * Unified resource and prompt capabilities under standard JSON-RPC schema

## 0.1.0

* Initial release
* Created Model Context Protocol (MCP) implementation for Dart
* Features:
  * Create MCP servers with standardized protocol support
  * Expose data through Resources
  * Provide functionality through Tools
  * Define interaction patterns through Prompts
  * Multiple transport layers:
    * Standard I/O for local process communication
    * Server-Sent Events (SSE) for HTTP-based communication
  * Platform support: Android, iOS, web, Linux, Windows, macOS