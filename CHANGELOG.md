## [2.2.3] - 2026-07-31 - `strictMode: false` now does something

### Fixed

`enableAuthentication(validator, strictMode: false)` is documented as "validate what is offered, let the rest through". `AuthMiddleware` honoured it on the HTTP path, but the JSON-RPC request path never consulted it: `_authenticateRequest` returned a hard failure whenever no token was present, so the option was inert exactly where it decides whether a request is answered.

The shape it exists for is common and was unreachable — an origin that is **public but personalizes for a signed-in caller**. Enabling authentication to *observe* a credential turned the origin private: every visitor arriving without one was refused. That is what a guest-then-promote surface does by default, so the mode that supports it should not have been the one that broke it.

Found while building a public probe origin for the web runner: turning on a recording validator to see what a page attached refused every anonymous visitor. Three regressions drive a real session over a socket (a credential has to survive `initialize` → `resources/read`), and the guard is mutation-checked. The strict default is unchanged and separately pinned.

## [2.2.2] - 2026-07-31 - The caller's credential reaches the handler

### Fixed

- `AuthContext.token` is populated. It is a documented public field that
  nothing had ever filled: the credential existed only as a local inside the
  authentication helper, and the verdict it returned carries no token, so a
  handler could learn everything about the caller except the token they
  presented. `McpCaller.current!.token` was therefore always null.

  This matters for a runtime that must act *as* the caller — forwarding a
  request outward under the caller's own grant instead of holding a credential
  of its own. Holding one is what that design avoids: a runtime that can ask
  for a given user's data on its own authority is not isolated.

  The credential is returned alongside the verdict rather than folded into
  `AuthResult`. That type is public and hosts construct it in their own
  `TokenValidator`, so carrying the credential there would put it on a value
  hosts build themselves — where it would go unset again.

  Present since the field was introduced; every version through 2.2.1 has it
  empty. It survived because the tests covering `AuthContext` assert on
  `userId` and `scopes`, and none looked at `token`.

### Deprecated

- `ClientSession.authToken`. Nothing in this package ever assigned it, so the
  branch that read it as a fallback token source could not fire; that read is
  removed. Making it fire would mean a session that authenticated once stays
  authenticated for every later request on it — wrong wherever one connection
  carries requests for different users, which is the case per-request identity
  exists to serve. Removal in 3.0.

## [2.2.1] - 2026-07-30 - Browser-reachable CORS, completed

### Fixed

- The CORS allow-list now covers every header a conformant client sends. It was
  missing `Cache-Control` (sent on the SSE stream) and `Mcp-Method` / `Mcp-Name`
  (**required** on the 2026-07-28 path, so a browser could not use that revision
  at all), plus `X-Heartbeat-Interval` from the compressed-SSE transport.

  A browser refuses to issue a request carrying a header the server has not
  allowed, and it refuses before anything reaches the server — the call fails as
  an opaque network error with nothing in the server log.

  2.1.2 fixed this same class for `MCP-Protocol-Version`. It recurred because a
  preflight reports **one** disallowed header at a time, so fixing whichever the
  browser last named guarantees another round. The allow-list is now pinned
  against the set the client actually sends, by a test that asks a live socket
  and by a conformance axis that asks a real browser — a unit test can only
  check the string, and the browser is the one that enforces it.

## [2.2.0] - 2026-07-30 - Request-scoped caller

Additive. No public API removed, no signature changes.

### Added

- `McpCaller.current` — the authenticated caller of the request being handled,
  readable from tool, resource, and prompt handlers. Returns the request's
  `AuthContext` (`userId`, `scopes`, `hasScope`), or `null` when the server has
  no auth middleware, the method requires no auth, or the call is not inside a
  request. `AuthContext.userInfo` is whatever the configured `TokenValidator`
  returned.

### Fixed

- A bearer token in the `Authorization` header now reaches the validator
  installed by `enableAuthentication`. The token was read only from the
  JSON-RPC body and the session, and the Streamable HTTP transport populates
  neither from the header, so a standard client's authenticated request was
  refused as carrying no token and the validator was never called. Header
  authentication was therefore unusable; only a token placed in `params`
  worked, which no standard client sends.

  The transport now carries the credential on the reserved `_authorization`
  control key, stripped from client input at every ingestion boundary so a
  request body cannot present one the transport did not read off the wire.
  Applies to the plain, stateless and batch POST paths. Independent of
  `config.authToken`, which is a static shared secret the transport compares
  itself.

## [2.1.2] - 2026-07-30 - Specification conformance + browser reachability

### Fixed — specification conformance (verified against reference implementations)

Found by running this server against the official TypeScript SDK and, for
revision `2026-07-28`, the official Python SDK — none of these are visible when
both ends are ours, because a mistake made on both sides passes.

- `ping` answers with an empty result. It carried `pong` and a timestamp, which
  a peer that validates result shapes rejects outright.
- `resources/subscribe` / `resources/unsubscribe` answer with an empty result
  instead of `{"success": true}`.
- `resources/templates/list` returns templates registered through
  `addResourceTemplate`. The handler read a different store than the
  registration wrote to, so a registered template could never appear.
- Progress notifications carry the client's `_meta.progressToken`. The server
  minted its own token, which correlates with nothing on the client, so a
  progress-reporting tool delivered nothing. `addToolWithProgress` also minted
  an operation id of its own rather than using the one the call was registered
  under; the operation is now published on the zone the handler runs in.
- Revision `2026-07-28` only: caching hints (`ttlMs`, `cacheScope`) on the
  results the specification requires them on; the standard request headers
  (`Mcp-Method`, `Mcp-Name`, including the base64 sentinel form) are required
  and validated against the body; a request missing the required `_meta` is
  rejected with `-32602`; a request whose declared capabilities are absent is
  rejected with `-32021`. Notifications are exempt — this revision does not
  define header requirements for them.
- A request naming a protocol revision this build does not implement is
  answered with `-32022` and the list of supported versions. It previously fell
  through to the legacy path and returned a bare `-32600`, which leaves a
  client nothing to retry with.

### Changed — internal floor

- `mcp_client` floor raised to `^2.1.1`. This server now requires the standard
  request headers on the 2026-07-28 path, and 2.1.1 is the release that sends
  them; resolved against 2.1.0 the stateless suites fail.

### Changed — `Origin` is validated by default

The specification requires servers to validate `Origin` to prevent DNS
rebinding. Enforcement was opt-in and off, so a default deployment accepted a
browser request from any site. The default allow-list is now the local machine
(`localhost` / `127.0.0.1` / `[::1]`); name other origins with `allowedOrigins`,
or set the new `allowAnyOrigin` for deployments that terminate the check in
front of the server. Requests without an `Origin` header are unaffected — they
did not come from a browser.

**This can reject traffic a previous version accepted.** A server reached from
a browser on another origin must now name it.

### Added

- `corsConfig`, `allowedOrigins`, `allowAnyOrigin` and `enableStateless` on the
  Streamable HTTP transport factories. They were configurable on the config
  object but unreachable through the factory, which is the documented way to
  build a transport — so `authToken` could be set and the security-relevant
  settings could not. `CorsConfig` is now exported.

### Fixed — browser clients could not reach this server
- `Access-Control-Allow-Headers` now includes `MCP-Protocol-Version`. Clients
  send it from spec revision 2025-11-25 on, and a browser refuses the request
  outright when a sent header is not allowed — the call failed as an opaque
  `Failed to fetch` before it ever reached the server, so no server-side log
  showed anything wrong.
- New `CorsConfig.exposeHeaders`, emitted as `Access-Control-Expose-Headers`
  (`mcp-session-id`, `MCP-Protocol-Version`, `WWW-Authenticate`). A browser
  hides every non-simple response header, so a client could negotiate a session
  it was then unable to read, and every following request would arrive without
  one.

Found by connecting a browser build to this server, not by inspection: both
defects are invisible to a non-browser client.

Default values only; no public API removed. `CorsConfig` gains `exposeHeaders`.

## [2.1.1] - 2026-07-28 - Session-scoped in-flight request tracking

Bug fix. No public API change; the JSON-RPC wire contract is unchanged (request
ids are never rewritten — a client always gets its own id back).

### Fixed
- `StreamableHttpServerTransport` tracked in-flight requests by the bare
  JSON-RPC id. Since JSON-RPC 2.0 guarantees id uniqueness only *within* a
  session, and clients commonly count from 1 per connection, two concurrent
  sessions using the same id collided: the second registration overwrote the
  first, whose `HttpResponse` was then unreachable and never written or closed
  (that caller received 0 bytes until its own timeout), and a response could be
  delivered to the wrong session. Every in-flight map — pending requests, sync
  and async JSON completers, stateless completers, batch completers, SSE
  streams, message routers and stateless subscription streams — is now keyed by
  `(session, id)`.
- `Server` now stamps `_targetSessionId` on responses and on stateless
  subscription messages, as it already did for notifications and
  server-initiated requests; the response path was the one place the session
  axis was dropped. A response that arrives without it is refused rather than
  matched on the bare id.
- Transport-internal routing metadata (`_targetSessionId`) is stripped before
  encoding on every transport. The stdio and SSE transports previously emitted
  it on the wire for notifications.
- A stateless `subscriptions/listen` is registered per session, so two clients
  choosing the same listen id no longer evict one another. A cancellation that
  cannot be attributed to a single subscription is refused rather than closing
  an arbitrary client's stream.

## [2.1.0] - 2026-07-19 - 2025-11-25 conformance + 2026-07-28 stateless core (dormant)

Additive, backward-compatible (all new fields optional/named; `==`/`hashCode`
unchanged; behavior changes are negotiated-version gated — older peers keep prior
behavior). No public API removed.

### Added — 2025-11-25 conformance
- DNS-rebinding protection: `StreamableHttpServerConfig.allowedOrigins` → HTTP 403
  on a disallowed `Origin` (opt-in; default null = prior behavior).
- Tool-execution errors returned as an `isError` `CallToolResult` (SEP-1303),
  gated to 2025-11-25+ (older peers keep the JSON-RPC protocol error).
- SSE event replay / resumability implemented (`Last-Event-ID`, SEP-1699).
- Sampling `tools`/`toolChoice` (`SamplingTool`, `ToolChoice`); typed elicitation
  (`EnumSchema`, single/multi-select, URL-mode, defaults); `Server.description`
  emitted in `serverInfo`; JSON Schema 2020-12 dialect helper; opt-in stderr log
  sink (`attachStderrLogSink`).
- OAuth: 401 emits `WWW-Authenticate: Bearer resource_metadata=…` (RFC 9728) +
  optional `challengeScope` (SEP-835) when PRM is configured.

### Fixed
- JSON-RPC batching now works over Streamable HTTP for sessions that negotiated
  2024-11-05 / 2025-03-26. The transport previously hard-cast every request body
  to an object, so a batch array was rejected with a `-32700` parse error before
  the (already-implemented, version-gated) batch dispatch ran. Array bodies are
  now routed through a version-gated batch handler that dispatches each entry and
  returns a single JSON array of responses; 2025-06-18+ sessions correctly reject
  a batch with `-32600` (removed in 2025-06-18), not a parse error.
- **Security — dormancy hardening.** A client could activate the dormant
  2026-07-28 stateless path by forging the transport-internal `_stateless`
  control key in its request body (over HTTP / stdio / SSE), flipping the server
  into stateless mode and leaking `2026-07-28` in `server/discover` even with
  `enableStateless` off. The stateless router now honors `_stateless` only when
  the connected transport genuinely has stateless enabled, and every ingestion
  boundary strips client-forged reserved keys (`_stateless` / `_protocolVersion`
  / `_sessionId`).
- Version-gated feature predicates that are "introduced and carried forward"
  (`toolErrorsAsResult`, `defaultsJsonSchemaDialect`, `supportsElicitation`,
  `requiresProtocolHeader`, `supportsStructuredToolOutput`,
  `supportsIconsAndSamplingTools`) now use an "at least this revision" date
  comparison instead of `== <exact revision>`, so they stay enabled for later
  revisions (e.g. 2026-07-28) instead of silently regressing. `supportsBatching`
  stays a bounded legacy set (removed in 2025-06-18). No change for the four
  currently-negotiable revisions.

### Deprecated
- `CallToolResult.isStreaming` — non-standard hint, honored nowhere. Standard
  streaming = enable via a tool (`tools/call`) + deliver via a reactive resource
  (`subscriptions/listen`, or legacy `resources/subscribe`). Retained +
  serialized for backward compatibility; removed in 3.0.

### Added — 2026-07-28 stateless core (BUILD-DORMANT, opt-in via `StreamableHttpServerConfig.enableStateless`, default false)
- `_meta` reverse-DNS keys (`McpRequestMeta`), `server/discover` + shared
  `Server.describe()`, stateless request routing (no session), Multi-Round-Trip
  (`InputRequiredResult`), `subscriptions/listen`, Extensions framework
  (`ServerCapabilities.extensions`), Tasks extension (task store + `tasks/get` /
  `tasks/update` / `tasks/cancel`, gated on the tasks extension), resource-not-found
  `-32602` on the stateless path.
- Inert until enabled — the full handshake/session path is unchanged; zero behavior
  change for existing consumers.

## [2.0.0] - 2026-04-30 - MCP spec compliance + 2025-11-25 alignment

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