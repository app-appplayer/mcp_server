# MCP Server Test Suite

This directory contains comprehensive tests for the MCP Server implementation, focusing on the 2025-03-26 specification compliance and security features.

## Test Files Overview

### Core Functionality Tests
- **`mcp_server_test.dart`** - Basic MCP server functionality tests
- **`server_basic_test.dart`** - Fundamental server operations and lifecycle
- **`session_events_test.dart`** - Session management and event handling

### MCP 2025 Specification Tests
- **`mcp_server_2025_features_test.dart`** - MCP 2025-03-26 feature compliance
- **`mcp_server_2025_batch_test.dart`** - Batch operation support tests
- **`mcp_server_2025_oauth_test.dart`** - OAuth 2.1 authentication tests

### Transport Security Tests
- **`streamable_http_authentication_test.dart`** - **NEW: Comprehensive StreamableHTTP authentication tests**

## StreamableHTTP Authentication Tests

The `streamable_http_authentication_test.dart` file provides complete coverage of Bearer token authentication:

### Test Groups

#### 1. Bearer Token Validation
- ✅ Valid Bearer token acceptance
- ✅ Invalid Bearer token rejection (401)
- ✅ Missing Authorization header rejection (401)
- ✅ Malformed Authorization header rejection (401)

#### 2. HTTP Methods Authentication
- ✅ POST request authentication
- ✅ GET request authentication (SSE stream)
- ✅ DELETE request authentication (session termination)

#### 3. Authentication Disabled Mode
- ✅ Requests allowed when `authToken` is `null`

#### 4. Factory Methods and API Support
- ✅ `createStreamableHttpTransport()` authToken parameter
- ✅ `createStreamableHttpTransportAsync()` authToken parameter
- ✅ Unified API `TransportConfig.streamableHttp()` authToken parameter

#### 5. Security Compliance
- ✅ Consistency with SSE transport authentication
- ✅ Proper error messages for auth failures
- ✅ MCP 2025-03-26 standard compliance

#### 6. Edge Cases
- ✅ Empty Bearer token handling
- ✅ Case-sensitive Bearer token validation

## Running Tests

### Run All Tests
```bash
dart test
```

### Run Specific Test Files
```bash
# Run authentication tests only
dart test test/streamable_http_authentication_test.dart

# Run MCP 2025 feature tests
dart test test/mcp_server_2025_features_test.dart

# Run OAuth tests
dart test test/mcp_server_2025_oauth_test.dart
```

### Run Tests with Verbose Output
```bash
dart test --reporter=expanded
```

## Test Coverage

The test suite covers:

1. **Authentication & Security**
   - Bearer token validation
   - OAuth 2.1 compliance
   - Transport security consistency
   - Error handling and proper HTTP status codes

2. **MCP Protocol Compliance**
   - Protocol version negotiation
   - Method definitions and capabilities
   - Request/response format validation
   - Batch operation support

3. **Transport Layer**
   - StreamableHTTP transport functionality
   - SSE (Server-Sent Events) support
   - Session management
   - Error propagation

4. **Server Lifecycle**
   - Initialization and shutdown
   - Connection management
   - Event handling
   - Resource cleanup

## Security Test Summary

**Critical Security Fix Verified:**
- ❌ **Before**: StreamableHTTP had no Bearer token authentication
- ✅ **After**: StreamableHTTP implements the same authentication as SSE
- ✅ **Result**: MCP standard compliance achieved across all transports

## Test Environment

- **Dart SDK**: Compatible with project requirements
- **Test Framework**: `package:test`
- **Network Tests**: Uses ephemeral ports (8500-8599) to avoid conflicts
- **Timeout**: Configured for CI/CD environments

## Contributing

When adding new tests:

1. Place tests in appropriate files based on functionality
2. Use descriptive test names and group organization
3. Include both positive and negative test cases
4. Add proper teardown for network resources
5. Update this README if adding new test categories