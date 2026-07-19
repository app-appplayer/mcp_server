/// Pure-logic coverage for `lib/src/protocol/protocol.dart` —
/// `McpProtocol.negotiate` (simple best-match negotiation, distinct from
/// `Server.negotiateVersion`) and `McpErrorCodes.getMessage` (every branch
/// of the code → message switch, including the fallback).
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

void main() {
  group('McpProtocol.negotiate', () {
    test('returns the first server version the client also supports', () {
      final result = McpProtocol.negotiate(
        ['2024-11-05', '2025-03-26', '2025-06-18'],
        ['2025-11-25', '2025-06-18', '2025-03-26'],
      );
      expect(result, '2025-06-18');
    });

    test('returns the first (highest-preference) server version on multiple '
        'matches', () {
      final result = McpProtocol.negotiate(
        ['2024-11-05', '2025-03-26'],
        ['2025-03-26', '2024-11-05'],
      );
      expect(result, '2025-03-26');
    });

    test('returns null when there is no overlap', () {
      final result = McpProtocol.negotiate(
        ['1999-01-01'],
        ['2025-11-25', '2025-06-18'],
      );
      expect(result, isNull);
    });

    test('returns null for an empty server version list', () {
      final result = McpProtocol.negotiate(['2025-11-25'], []);
      expect(result, isNull);
    });
  });

  group('McpErrorCodes.getMessage', () {
    test('maps every defined code to its message', () {
      expect(McpErrorCodes.getMessage(McpErrorCodes.parseError), 'Parse error');
      expect(McpErrorCodes.getMessage(McpErrorCodes.invalidRequest),
          'Invalid request');
      expect(McpErrorCodes.getMessage(McpErrorCodes.methodNotFound),
          'Method not found');
      expect(McpErrorCodes.getMessage(McpErrorCodes.invalidParams),
          'Invalid params');
      expect(McpErrorCodes.getMessage(McpErrorCodes.internalError),
          'Internal error');
      expect(McpErrorCodes.getMessage(McpErrorCodes.toolNotFound),
          'Tool not found');
      expect(McpErrorCodes.getMessage(McpErrorCodes.resourceNotFound),
          'Resource not found');
      expect(McpErrorCodes.getMessage(McpErrorCodes.promptNotFound),
          'Prompt not found');
      expect(McpErrorCodes.getMessage(McpErrorCodes.cancelled),
          'Operation cancelled');
      expect(
          McpErrorCodes.getMessage(McpErrorCodes.timeout), 'Operation timeout');
      expect(McpErrorCodes.getMessage(McpErrorCodes.permissionDenied),
          'Permission denied');
      expect(
          McpErrorCodes.getMessage(McpErrorCodes.rateLimited), 'Rate limited');
      expect(
          McpErrorCodes.getMessage(McpErrorCodes.networkError), 'Network error');
      expect(McpErrorCodes.getMessage(McpErrorCodes.protocolError),
          'Protocol error');
    });

    test('falls back to "Unknown error" for an unrecognized code', () {
      expect(McpErrorCodes.getMessage(-1), 'Unknown error');
      expect(McpErrorCodes.getMessage(0), 'Unknown error');
    });
  });

  group('McpMethods constants', () {
    test('spot-check a few method name constants', () {
      expect(McpMethods.initialize, 'initialize');
      expect(McpMethods.ping, 'ping');
      expect(McpMethods.shutdown, 'shutdown');
      expect(McpMethods.listTools, 'tools/list');
      expect(McpMethods.callTool, 'tools/call');
      expect(McpMethods.listResources, 'resources/list');
      expect(McpMethods.readResource, 'resources/read');
      expect(McpMethods.subscribeResource, 'resources/subscribe');
      expect(McpMethods.unsubscribeResource, 'resources/unsubscribe');
      expect(McpMethods.listResourceTemplates, 'resources/templates/list');
      expect(McpMethods.listPrompts, 'prompts/list');
      expect(McpMethods.getPrompt, 'prompts/get');
      expect(McpMethods.setLoggingLevel, 'logging/setLevel');
      expect(McpMethods.createMessage, 'sampling/createMessage');
      expect(McpMethods.listRoots, 'roots/list');
      expect(McpMethods.completeArgument, 'completion/complete');
      expect(McpMethods.notificationCancelled, 'notifications/cancelled');
      expect(McpMethods.notificationProgress, 'notifications/progress');
      expect(McpMethods.notificationResourcesListChanged,
          'notifications/resources/list_changed');
      expect(McpMethods.notificationToolsListChanged,
          'notifications/tools/list_changed');
      expect(McpMethods.notificationPromptsListChanged,
          'notifications/prompts/list_changed');
      expect(McpMethods.notificationRootsListChanged,
          'notifications/roots/list_changed');
      expect(McpMethods.notificationMessage, 'notifications/message');
    });
  });
}
