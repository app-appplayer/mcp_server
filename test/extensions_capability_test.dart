/// Extensions framework (MCP 2026-07-28) — ServerCapabilities `extensions`
/// map round-trip + `hasExtension`. Additive; absent by default.
library;

import 'package:mcp_server/mcp_server.dart';
import 'package:test/test.dart';

void main() {
  group('Extensions framework — ServerCapabilities', () {
    test('extensions map serializes under capabilities.extensions', () {
      const caps = ServerCapabilities(
        tools: ToolsCapability(),
        extensions: {
          'io.modelcontextprotocol/tasks': {},
          'io.example/thing': {'setting': 1},
        },
      );
      final json = caps.toJson();
      expect(json['extensions'], {
        'io.modelcontextprotocol/tasks': {},
        'io.example/thing': {'setting': 1},
      });
      expect(caps.hasExtension('io.modelcontextprotocol/tasks'), isTrue);
      expect(caps.hasExtension('io.example/thing'), isTrue);
      expect(caps.hasExtension('io.absent/x'), isFalse);
    });

    test('absent extensions omits the key (backward compatible)', () {
      const caps = ServerCapabilities(tools: ToolsCapability());
      expect(caps.toJson().containsKey('extensions'), isFalse);
      expect(caps.hasExtension('io.modelcontextprotocol/tasks'), isFalse);
    });

    test('empty extensions map omits the key', () {
      const caps = ServerCapabilities(tools: ToolsCapability(), extensions: {});
      expect(caps.toJson().containsKey('extensions'), isFalse);
    });
  });
}
