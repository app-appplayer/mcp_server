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