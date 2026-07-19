/// Pure-logic coverage for `lib/src/protocol/error.dart` — `McpErrorCode`
/// (category / retryable / critical predicates), `McpServerError` (every
/// named factory, `toJsonRpcError`, `toHttpStatusCode`, `toJson`, `toString`,
/// equality), `McpServerErrorHandler` (exception classification + method /
/// params / auth / resource / tool validation), `ErrorSeverity`, and
/// `ServerErrorContext`.
///
/// This file is NOT re-exported from `package:mcp_server/mcp_server.dart`
/// (it predates / duplicates the exported `McpErrorCodes` in
/// `protocol.dart` and is unused elsewhere in `lib/`) — it is imported here
/// by its `src/` path, which is a normal, supported way to unit-test a
/// library file that isn't part of the public barrel.
@TestOn('vm')
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:mcp_server/src/protocol/error.dart';

void main() {
  group('McpErrorCode', () {
    test('fromCode finds the matching enum value', () {
      expect(McpErrorCode.fromCode(-32700), McpErrorCode.parseError);
      expect(McpErrorCode.fromCode(-32104), McpErrorCode.unauthorized);
    });

    test('fromCode returns null for an unknown code', () {
      expect(McpErrorCode.fromCode(-1), isNull);
    });

    test('code and message accessors', () {
      expect(McpErrorCode.methodNotFound.code, -32601);
      expect(McpErrorCode.methodNotFound.message, 'Method not found');
    });

    test('isJsonRpcError covers the -32768..-32000 reserved range — every '
        'code in this enum falls inside it, MCP-specific ones included',
        () {
      expect(McpErrorCode.parseError.isJsonRpcError, isTrue);
      expect(McpErrorCode.serverError.isJsonRpcError, isTrue);
      // -32100 is still >= -32768, so this is true too (the getter's range
      // is the full reserved band, not just the six core JSON-RPC codes).
      expect(McpErrorCode.resourceNotFound.isJsonRpcError, isTrue);
    });

    test('isMcpError covers the MCP-specific range', () {
      expect(McpErrorCode.resourceNotFound.isMcpError, isTrue);
      expect(McpErrorCode.parseError.isMcpError, isFalse);
    });

    test('isAuthError covers the auth range', () {
      expect(McpErrorCode.authenticationRequired.isAuthError, isTrue);
      expect(McpErrorCode.tokenInvalid.isAuthError, isTrue);
      expect(McpErrorCode.unauthorized.isAuthError, isFalse);
    });

    test('isTransportError covers the transport range', () {
      expect(McpErrorCode.connectionLost.isTransportError, isTrue);
      expect(McpErrorCode.compressionError.isTransportError, isTrue);
      expect(McpErrorCode.parseError.isTransportError, isFalse);
    });

    test('isResourceError covers the resource range', () {
      expect(McpErrorCode.resourceLocked.isResourceError, isTrue);
      expect(McpErrorCode.resourceAccessDenied.isResourceError, isTrue);
      expect(McpErrorCode.resourceNotFound.isResourceError, isFalse);
    });

    test('isToolError covers the tool range', () {
      expect(McpErrorCode.toolUnavailable.isToolError, isTrue);
      expect(McpErrorCode.toolDependencyMissing.isToolError, isTrue);
      expect(McpErrorCode.toolNotFound.isToolError, isFalse);
    });

    test('isServerError covers the server range', () {
      expect(McpErrorCode.serverOverloaded.isServerError, isTrue);
      expect(McpErrorCode.storageError.isServerError, isTrue);
      expect(McpErrorCode.internalError.isServerError, isFalse);
    });

    test('isRetryable is true only for the designated retryable codes', () {
      expect(McpErrorCode.rateLimited.isRetryable, isTrue);
      expect(McpErrorCode.timeoutError.isRetryable, isTrue);
      expect(McpErrorCode.serverOverloaded.isRetryable, isTrue);
      expect(McpErrorCode.resourceUnavailable.isRetryable, isTrue);
      expect(McpErrorCode.toolUnavailable.isRetryable, isTrue);
      expect(McpErrorCode.storageError.isRetryable, isTrue);
      expect(McpErrorCode.parseError.isRetryable, isFalse);
    });

    test('isCritical is true only for the designated critical codes', () {
      expect(McpErrorCode.internalError.isCritical, isTrue);
      expect(McpErrorCode.incompatibleVersion.isCritical, isTrue);
      expect(McpErrorCode.protocolError.isCritical, isTrue);
      expect(McpErrorCode.resourceCorrupted.isCritical, isTrue);
      expect(McpErrorCode.dependencyError.isCritical, isTrue);
      expect(McpErrorCode.configurationError.isCritical, isTrue);
      expect(McpErrorCode.parseError.isCritical, isFalse);
    });
  });

  group('McpServerError factories', () {
    test('standard() uses the code default message when none given', () {
      final err = McpServerError.standard(McpErrorCode.rateLimited);
      expect(err.code, McpErrorCode.rateLimited);
      expect(err.message, 'Rate limited');
      expect(err.data, isNull);
      expect(err.requestId, isNull);
      expect(err.traceId, isNull);
      expect(err.retryAfter, isNull);
    });

    test('standard() honors a custom message and extra fields', () {
      final err = McpServerError.standard(
        McpErrorCode.internalError,
        customMessage: 'db down',
        data: {'x': 1},
        requestId: 7,
        traceId: 't-1',
        retryAfter: 30,
      );
      expect(err.message, 'db down');
      expect(err.data, {'x': 1});
      expect(err.requestId, 7);
      expect(err.traceId, 't-1');
      expect(err.retryAfter, 30);
    });

    test('parseError() with and without details', () {
      final withDetails = McpServerError.parseError(details: 'bad token');
      expect(withDetails.code, McpErrorCode.parseError);
      expect(withDetails.message, 'Parse error: bad token');

      final noDetails = McpServerError.parseError();
      expect(noDetails.message, 'Parse error');
    });

    test('invalidRequest() with and without details', () {
      final withDetails =
          McpServerError.invalidRequest(details: 'missing id');
      expect(withDetails.message, 'Invalid request: missing id');
      final noDetails = McpServerError.invalidRequest();
      // Falls back to McpErrorCode.invalidRequest.message verbatim (note:
      // capitalized "Request", distinct from the "Invalid request: ..."
      // custom-message form above).
      expect(noDetails.message, 'Invalid Request');
    });

    test('methodNotFound() carries the method name in message and data', () {
      final err = McpServerError.methodNotFound('tools/frobnicate');
      expect(err.code, McpErrorCode.methodNotFound);
      expect(err.message, 'Method not found: tools/frobnicate');
      expect(err.data, {'method': 'tools/frobnicate'});
    });

    test('invalidParams() with and without details', () {
      final withDetails = McpServerError.invalidParams(details: 'need x');
      expect(withDetails.message, 'Invalid params: need x');
      final noDetails = McpServerError.invalidParams();
      expect(noDetails.message, 'Invalid params');
    });

    test('resourceNotFound() carries the uri', () {
      final err = McpServerError.resourceNotFound('file:///missing');
      expect(err.code, McpErrorCode.resourceNotFound);
      expect(err.message, 'Resource not found: file:///missing');
      expect(err.data, {'uri': 'file:///missing'});
    });

    test('toolNotFound() carries the tool name', () {
      final err = McpServerError.toolNotFound('frobnicate');
      expect(err.code, McpErrorCode.toolNotFound);
      expect(err.message, 'Tool not found: frobnicate');
      expect(err.data, {'tool': 'frobnicate'});
    });

    test('toolExecutionError() carries tool name and details', () {
      final err = McpServerError.toolExecutionError('frobnicate', 'timed out');
      expect(err.code, McpErrorCode.toolExecutionError);
      expect(err.message, 'Tool execution failed: frobnicate - timed out');
      expect(err.data, {'tool': 'frobnicate', 'details': 'timed out'});
    });

    test('unauthorized() with and without details', () {
      final withDetails = McpServerError.unauthorized(details: 'no token');
      expect(withDetails.message, 'Unauthorized: no token');
      final noDetails = McpServerError.unauthorized();
      expect(noDetails.message, 'Unauthorized');
    });

    test('rateLimited() with and without retryAfterSeconds', () {
      final withRetry = McpServerError.rateLimited(retryAfterSeconds: 15);
      expect(withRetry.message, 'Rate limited. Retry after 15 seconds');
      expect(withRetry.data, {'retry_after': 15});
      expect(withRetry.retryAfter, 15);

      final noRetry = McpServerError.rateLimited();
      expect(noRetry.message, 'Rate limited');
      expect(noRetry.data, isNull);
    });

    test('serverOverloaded() with and without retryAfterSeconds', () {
      final withRetry =
          McpServerError.serverOverloaded(retryAfterSeconds: 5);
      expect(withRetry.data, {'retry_after': 5});
      expect(withRetry.retryAfter, 5);

      final noRetry = McpServerError.serverOverloaded();
      expect(noRetry.data, isNull);
      expect(noRetry.retryAfter, isNull);
    });

    test('internal() with and without details/traceId', () {
      final withDetails =
          McpServerError.internal(details: 'oops', traceId: 't-9');
      expect(withDetails.message, 'Internal server error: oops');
      expect(withDetails.traceId, 't-9');

      final noDetails = McpServerError.internal();
      expect(noDetails.message, 'Internal error');
    });
  });

  group('McpServerError.toJsonRpcError', () {
    test('minimal error has no data key', () {
      final err = McpServerError.standard(McpErrorCode.parseError);
      final rpc = err.toJsonRpcError();
      expect(rpc['jsonrpc'], '2.0');
      expect(rpc['error'], {'code': -32700, 'message': 'Parse error'});
      expect(rpc.containsKey('id'), isFalse);
    });

    test('combines data, traceId, retryAfter into error.data, and includes '
        'id when requestId is set', () {
      final err = McpServerError.standard(
        McpErrorCode.rateLimited,
        data: {'scope': 'tools'},
        requestId: 42,
        traceId: 'trace-1',
        retryAfter: 10,
      );
      final rpc = err.toJsonRpcError();
      expect(rpc['id'], 42);
      final errorObj = rpc['error'] as Map;
      expect(errorObj['data'], {
        'scope': 'tools',
        'trace_id': 'trace-1',
        'retry_after': 10,
      });
    });
  });

  group('McpServerError.toHttpStatusCode', () {
    test('maps each error family to its HTTP status', () {
      const cases = <McpErrorCode, int>{
        McpErrorCode.parseError: 400,
        McpErrorCode.invalidRequest: 400,
        McpErrorCode.invalidParams: 400,
        McpErrorCode.validationError: 400,
        McpErrorCode.unauthorized: 401,
        McpErrorCode.authenticationRequired: 401,
        McpErrorCode.authenticationFailed: 401,
        McpErrorCode.tokenExpired: 401,
        McpErrorCode.tokenInvalid: 401,
        McpErrorCode.insufficientPermissions: 403,
        McpErrorCode.resourceAccessDenied: 403,
        McpErrorCode.methodNotFound: 404,
        McpErrorCode.resourceNotFound: 404,
        McpErrorCode.toolNotFound: 404,
        McpErrorCode.promptNotFound: 404,
        McpErrorCode.conflictError: 409,
        McpErrorCode.resourceLocked: 409,
        McpErrorCode.resourceTooLarge: 413,
        McpErrorCode.incompatibleVersion: 422,
        McpErrorCode.rateLimited: 429,
        McpErrorCode.quotaExceeded: 429,
        McpErrorCode.internalError: 500,
        McpErrorCode.serverError: 500,
        McpErrorCode.configurationError: 500,
        McpErrorCode.dependencyError: 500,
        McpErrorCode.toolUnavailable: 503,
        McpErrorCode.resourceUnavailable: 503,
        McpErrorCode.maintenanceMode: 503,
        McpErrorCode.timeoutError: 504,
        McpErrorCode.connectionTimeout: 504,
        // A code outside every explicit case falls through to the default.
        McpErrorCode.operationCancelled: 500,
      };
      for (final entry in cases.entries) {
        final err = McpServerError.standard(entry.key);
        expect(err.toHttpStatusCode(), entry.value,
            reason: '${entry.key} should map to HTTP ${entry.value}');
      }
    });
  });

  group('McpServerError.toJson', () {
    test('includes codeName, httpStatus, and omits absent optional fields',
        () {
      final err = McpServerError.standard(McpErrorCode.toolNotFound,
          customMessage: 'x', requestId: 1);
      final json = err.toJson();
      expect(json['code'], -32101);
      expect(json['codeName'], 'toolNotFound');
      expect(json['message'], 'x');
      expect(json['requestId'], 1);
      expect(json['httpStatus'], 404);
      expect(json.containsKey('data'), isFalse);
      expect(json.containsKey('traceId'), isFalse);
      expect(json.containsKey('retryAfter'), isFalse);
      expect(json['timestamp'], isA<String>());
    });

    test('includes every optional field when present', () {
      final err = McpServerError.standard(
        McpErrorCode.rateLimited,
        data: {'x': 1},
        traceId: 't-1',
        retryAfter: 5,
      );
      final json = err.toJson();
      expect(json['data'], {'x': 1});
      expect(json['traceId'], 't-1');
      expect(json['retryAfter'], 5);
    });
  });

  group('McpServerError.toString', () {
    test('minimal error', () {
      final err = McpServerError(
        code: McpErrorCode.parseError,
        message: 'bad',
        timestamp: DateTime.utc(2026, 1, 1),
      );
      expect(err.toString(), 'McpServerError(parseError[-32700]: bad)');
    });

    test('includes data, requestId, and retryAfter when present', () {
      final err = McpServerError(
        code: McpErrorCode.rateLimited,
        message: 'slow down',
        data: const {'x': 1},
        requestId: 9,
        retryAfter: 12,
        timestamp: DateTime.utc(2026, 1, 1),
      );
      final s = err.toString();
      expect(s, contains('data: {x: 1}'));
      expect(s, contains('requestId: 9'));
      expect(s, contains('retryAfter: 12s'));
    });
  });

  group('McpServerError equality / hashCode', () {
    test('equal when code, message, and requestId match', () {
      final a = McpServerError(
        code: McpErrorCode.internalError,
        message: 'x',
        requestId: 1,
        timestamp: DateTime.utc(2026, 1, 1),
      );
      final b = McpServerError(
        code: McpErrorCode.internalError,
        message: 'x',
        requestId: 1,
        timestamp: DateTime.utc(2027, 1, 1), // timestamp is not part of ==
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(identical(a, a), isTrue);
      final Object other = 'not an error';
      expect(a == other, isFalse);
    });

    test('not equal when requestId differs', () {
      final a = McpServerError(
        code: McpErrorCode.internalError,
        message: 'x',
        requestId: 1,
        timestamp: DateTime.utc(2026, 1, 1),
      );
      final b = McpServerError(
        code: McpErrorCode.internalError,
        message: 'x',
        requestId: 2,
        timestamp: DateTime.utc(2026, 1, 1),
      );
      expect(a == b, isFalse);
    });
  });

  group('McpServerErrorHandler.fromException', () {
    test('an existing McpServerError is returned unchanged', () {
      final original = McpServerError.internal(details: 'x');
      expect(
          identical(McpServerErrorHandler.fromException(original), original),
          isTrue);
    });

    test('TimeoutException maps to timeoutError', () {
      final err = McpServerErrorHandler.fromException(
          TimeoutException('slow', const Duration(seconds: 1)));
      expect(err.code, McpErrorCode.timeoutError);
      expect(err.message, contains('Operation timed out'));
    });

    test('FormatException maps to a parse error', () {
      final err =
          McpServerErrorHandler.fromException(const FormatException('bad'));
      expect(err.code, McpErrorCode.parseError);
      expect(err.message, 'Parse error: bad');
    });

    test('ArgumentError maps to invalidParams', () {
      final err = McpServerErrorHandler.fromException(
          ArgumentError('missing field'));
      expect(err.code, McpErrorCode.invalidParams);
      expect(err.message, contains('missing field'));
    });

    test('any other exception falls back to internal error', () {
      final err =
          McpServerErrorHandler.fromException(StateError('unexpected'));
      expect(err.code, McpErrorCode.internalError);
      expect(err.message, contains('unexpected'));
    });

    test('passes through requestId (FormatException path — parseError() '
        'has no traceId parameter, so traceId is dropped there)', () {
      final err = McpServerErrorHandler.fromException(
        const FormatException('bad'),
        requestId: 5,
        traceId: 't-1',
      );
      expect(err.requestId, 5);
      expect(err.traceId, isNull);
    });

    test('passes through requestId and traceId on the fallback (internal '
        'error) path', () {
      final err = McpServerErrorHandler.fromException(
        StateError('unexpected'),
        requestId: 5,
        traceId: 't-1',
      );
      expect(err.requestId, 5);
      expect(err.traceId, 't-1');
    });
  });

  group('McpServerErrorHandler.validateMethod', () {
    test('null or empty method is invalid', () {
      expect(McpServerErrorHandler.validateMethod(null)?.code,
          McpErrorCode.invalidRequest);
      expect(McpServerErrorHandler.validateMethod('')?.code,
          McpErrorCode.invalidRequest);
    });

    test('an unrecognized method is methodNotFound', () {
      final err = McpServerErrorHandler.validateMethod('bogus/method');
      expect(err?.code, McpErrorCode.methodNotFound);
    });

    test('a recognized standard MCP method validates cleanly', () {
      expect(McpServerErrorHandler.validateMethod('tools/list'), isNull);
      expect(McpServerErrorHandler.validateMethod('initialize'), isNull);
    });
  });

  group('McpServerErrorHandler.validateParams', () {
    test('non-map params with required fields is invalid', () {
      final err = McpServerErrorHandler.validateParams(
          'not-a-map', {'name': true});
      expect(err?.code, McpErrorCode.invalidParams);
    });

    test('non-map params with no required fields is valid', () {
      expect(McpServerErrorHandler.validateParams(null, const {}), isNull);
    });

    test('missing a required field is invalid', () {
      final err = McpServerErrorHandler.validateParams(
        <String, dynamic>{'other': 1},
        {'name': true},
      );
      expect(err?.code, McpErrorCode.invalidParams);
      expect(err?.message, contains('name'));
    });

    test('an optional (non-required) missing field is fine', () {
      final err = McpServerErrorHandler.validateParams(
        <String, dynamic>{},
        {'name': false},
      );
      expect(err, isNull);
    });

    test('all required fields present validates cleanly', () {
      final err = McpServerErrorHandler.validateParams(
        <String, dynamic>{'name': 'x'},
        {'name': true},
      );
      expect(err, isNull);
    });
  });

  group('McpServerErrorHandler.validateAuth', () {
    test('null authContext is unauthorized', () {
      final err = McpServerErrorHandler.validateAuth(null, ['tools:read']);
      expect(err?.code, McpErrorCode.unauthorized);
    });

    test('missing required scopes yields insufficientPermissions', () {
      final err = McpServerErrorHandler.validateAuth(
        {'scopes': <String>['tools:read']},
        ['tools:read', 'tools:write'],
      );
      expect(err?.code, McpErrorCode.insufficientPermissions);
      expect(err?.data, {
        'required_scopes': ['tools:read', 'tools:write'],
        'user_scopes': ['tools:read'],
      });
    });

    test('all required scopes present validates cleanly', () {
      final err = McpServerErrorHandler.validateAuth(
        {'scopes': <String>['tools:read', 'tools:write']},
        ['tools:read'],
      );
      expect(err, isNull);
    });

    test('missing scopes key on authContext treats scopes as empty', () {
      final err = McpServerErrorHandler.validateAuth(
          <String, dynamic>{}, ['tools:read']);
      expect(err?.code, McpErrorCode.insufficientPermissions);
    });
  });

  group('McpServerErrorHandler.validateResourceExists', () {
    test('exists=false yields resourceNotFound', () {
      final err = McpServerErrorHandler.validateResourceExists(
          'file:///missing', false);
      expect(err?.code, McpErrorCode.resourceNotFound);
      expect(err?.data, {'uri': 'file:///missing'});
    });

    test('exists=true validates cleanly', () {
      expect(
        McpServerErrorHandler.validateResourceExists('file:///a', true),
        isNull,
      );
    });
  });

  group('McpServerErrorHandler.validateToolExists', () {
    test('exists=false yields toolNotFound', () {
      final err =
          McpServerErrorHandler.validateToolExists('frobnicate', false);
      expect(err?.code, McpErrorCode.toolNotFound);
      expect(err?.data, {'tool': 'frobnicate'});
    });

    test('exists=true validates cleanly', () {
      expect(
        McpServerErrorHandler.validateToolExists('frobnicate', true),
        isNull,
      );
    });
  });

  group('ErrorSeverity', () {
    test('has the four expected levels', () {
      expect(ErrorSeverity.values, [
        ErrorSeverity.info,
        ErrorSeverity.warning,
        ErrorSeverity.error,
        ErrorSeverity.critical,
      ]);
    });
  });

  group('ServerErrorContext', () {
    test('toJson with only required fields', () {
      final ctx = ServerErrorContext(
        operation: 'tools/call',
        timestamp: DateTime.utc(2026, 1, 1),
      );
      final json = ctx.toJson();
      expect(json['operation'], 'tools/call');
      expect(json['timestamp'], DateTime.utc(2026, 1, 1).toIso8601String());
      expect(json.containsKey('userId'), isFalse);
      expect(json.containsKey('sessionId'), isFalse);
      expect(json.containsKey('clientInfo'), isFalse);
      expect(json.containsKey('metadata'), isFalse);
    });

    test('toJson with every optional field', () {
      final ctx = ServerErrorContext(
        operation: 'tools/call',
        userId: 'u-1',
        sessionId: 's-1',
        clientInfo: 'test-client/1.0',
        metadata: {'x': 1},
        timestamp: DateTime.utc(2026, 1, 1),
      );
      final json = ctx.toJson();
      expect(json['userId'], 'u-1');
      expect(json['sessionId'], 's-1');
      expect(json['clientInfo'], 'test-client/1.0');
      expect(json['metadata'], {'x': 1});
    });
  });
}
