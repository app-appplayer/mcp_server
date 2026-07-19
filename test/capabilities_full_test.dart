/// Pure-logic coverage for `lib/src/protocol/capabilities.dart` —
/// `ServerCapabilities` (toJson, hasXxx / xxxListChanged getters, `.simple`
/// factory, `hasExtension`) and every individual capability class's toJson.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

void main() {
  group('ServerCapabilities.toJson', () {
    test('empty capabilities serialize to an empty map', () {
      const caps = ServerCapabilities();
      expect(caps.toJson(), <String, dynamic>{});
    });

    test('every capability field is serialized when present', () {
      const caps = ServerCapabilities(
        tools: ToolsCapability(listChanged: true, supportsProgress: true),
        resources: ResourcesCapability(subscribe: true, listChanged: false),
        prompts: PromptsCapability(listChanged: true),
        logging: LoggingCapability(),
        completions: CompletionsCapability(),
        sampling: SamplingCapability(),
        roots: RootsCapability(listChanged: true),
        progress: ProgressCapability(supportsProgress: true),
        extensions: {
          'io.modelcontextprotocol/tasks': <String, dynamic>{},
        },
      );
      final json = caps.toJson();
      expect(json['tools'], {'listChanged': true, 'supportsProgress': true});
      expect(json['resources'], {'subscribe': true, 'listChanged': false});
      expect(json['prompts'], {'listChanged': true});
      expect(json['logging'], <String, dynamic>{});
      expect(json['completions'], <String, dynamic>{});
      expect(json['sampling'], <String, dynamic>{});
      expect(json['roots'], {'listChanged': true});
      expect(json['progress'], {'supportsProgress': true});
      expect(json['extensions'],
          {'io.modelcontextprotocol/tasks': <String, dynamic>{}});
    });

    test('empty (non-null) extensions map is omitted from toJson', () {
      const caps = ServerCapabilities(extensions: {});
      expect(caps.toJson().containsKey('extensions'), isFalse);
    });
  });

  group('ServerCapabilities.hasExtension', () {
    test('true when the extension key is present, false otherwise', () {
      const caps = ServerCapabilities(extensions: {
        'io.modelcontextprotocol/tasks': <String, dynamic>{},
      });
      expect(caps.hasExtension('io.modelcontextprotocol/tasks'), isTrue);
      expect(caps.hasExtension('io.absent/x'), isFalse);
    });

    test('false when extensions is null', () {
      const caps = ServerCapabilities();
      expect(caps.hasExtension('anything'), isFalse);
    });
  });

  group('ServerCapabilities hasXxx getters', () {
    test('all false on an empty capability set', () {
      const caps = ServerCapabilities();
      expect(caps.hasTools, isFalse);
      expect(caps.hasResources, isFalse);
      expect(caps.hasPrompts, isFalse);
      expect(caps.hasLogging, isFalse);
      expect(caps.hasCompletions, isFalse);
      expect(caps.hasSampling, isFalse);
      expect(caps.hasRoots, isFalse);
      expect(caps.hasProgress, isFalse);
    });

    test('all true when every capability is set', () {
      const caps = ServerCapabilities(
        tools: ToolsCapability(),
        resources: ResourcesCapability(),
        prompts: PromptsCapability(),
        logging: LoggingCapability(),
        completions: CompletionsCapability(),
        sampling: SamplingCapability(),
        roots: RootsCapability(),
        progress: ProgressCapability(),
      );
      expect(caps.hasTools, isTrue);
      expect(caps.hasResources, isTrue);
      expect(caps.hasPrompts, isTrue);
      expect(caps.hasLogging, isTrue);
      expect(caps.hasCompletions, isTrue);
      expect(caps.hasSampling, isTrue);
      expect(caps.hasRoots, isTrue);
      expect(caps.hasProgress, isTrue);
    });
  });

  group('ServerCapabilities listChanged getters', () {
    test('default to false when the sub-capability or field is absent', () {
      const caps = ServerCapabilities();
      expect(caps.toolsListChanged, isFalse);
      expect(caps.resourcesListChanged, isFalse);
      expect(caps.promptsListChanged, isFalse);
      expect(caps.rootsListChanged, isFalse);
    });

    test('reflect the underlying listChanged flags when true', () {
      const caps = ServerCapabilities(
        tools: ToolsCapability(listChanged: true),
        resources: ResourcesCapability(listChanged: true),
        prompts: PromptsCapability(listChanged: true),
        roots: RootsCapability(listChanged: true),
      );
      expect(caps.toolsListChanged, isTrue);
      expect(caps.resourcesListChanged, isTrue);
      expect(caps.promptsListChanged, isTrue);
      expect(caps.rootsListChanged, isTrue);
    });
  });

  group('ServerCapabilities.simple', () {
    test('all flags false produces empty-capability sub-objects (all null)',
        () {
      final caps = ServerCapabilities.simple();
      expect(caps.hasTools, isFalse);
      expect(caps.hasResources, isFalse);
      expect(caps.hasPrompts, isFalse);
      expect(caps.hasSampling, isFalse);
      expect(caps.hasLogging, isFalse);
      expect(caps.hasCompletions, isFalse);
      expect(caps.hasRoots, isFalse);
      expect(caps.hasProgress, isFalse);
    });

    test('all flags true wires every sub-capability with listChanged', () {
      final caps = ServerCapabilities.simple(
        tools: true,
        toolsListChanged: true,
        resources: true,
        resourcesListChanged: true,
        prompts: true,
        promptsListChanged: true,
        sampling: true,
        logging: true,
        completions: true,
        roots: true,
        rootsListChanged: true,
        progress: true,
      );
      expect(caps.tools, isNotNull);
      expect(caps.toolsListChanged, isTrue);
      expect(caps.resources, isNotNull);
      expect(caps.resourcesListChanged, isTrue);
      expect(caps.prompts, isNotNull);
      expect(caps.promptsListChanged, isTrue);
      expect(caps.sampling, isNotNull);
      expect(caps.logging, isNotNull);
      expect(caps.completions, isNotNull);
      expect(caps.roots, isNotNull);
      expect(caps.rootsListChanged, isTrue);
      expect(caps.progress, isNotNull);
      expect(caps.hasProgress, isTrue);
    });
  });

  group('Individual capability toJson', () {
    test('ToolsCapability omits unset optional fields', () {
      expect(const ToolsCapability().toJson(), <String, dynamic>{});
      expect(const ToolsCapability(listChanged: false).toJson(),
          {'listChanged': false});
    });

    test('ResourcesCapability toJson with both fields set', () {
      expect(
        const ResourcesCapability(subscribe: true, listChanged: true)
            .toJson(),
        {'subscribe': true, 'listChanged': true},
      );
    });

    test('PromptsCapability toJson', () {
      expect(const PromptsCapability(listChanged: true).toJson(),
          {'listChanged': true});
      expect(const PromptsCapability().toJson(), <String, dynamic>{});
    });

    test('LoggingCapability toJson is always empty', () {
      expect(const LoggingCapability().toJson(), <String, dynamic>{});
    });

    test('CompletionsCapability toJson is always empty', () {
      expect(const CompletionsCapability().toJson(), <String, dynamic>{});
    });

    test('SamplingCapability toJson is always empty', () {
      expect(const SamplingCapability().toJson(), <String, dynamic>{});
    });

    test('RootsCapability toJson', () {
      expect(const RootsCapability(listChanged: true).toJson(),
          {'listChanged': true});
      expect(const RootsCapability().toJson(), <String, dynamic>{});
    });

    test('ProgressCapability toJson', () {
      expect(const ProgressCapability(supportsProgress: true).toJson(),
          {'supportsProgress': true});
      expect(const ProgressCapability().toJson(), <String, dynamic>{});
    });
  });
}
