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