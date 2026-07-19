/// Pure-logic coverage for `lib/src/annotations/tool_annotations.dart` —
/// `ToolAnnotationKeys`, `ToolPriority`, `ResourceUsage`, `DeprecationInfo`,
/// `ToolAnnotationBuilder`, `ToolAnnotationUtils`, and the
/// `ToolAnnotationPresets` factories, exercised end to end with real
/// assertions on the produced annotation maps.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

void main() {
  group('ToolPriority', () {
    test('toString returns the enum name', () {
      expect(ToolPriority.low.toString(), 'low');
      expect(ToolPriority.normal.toString(), 'normal');
      expect(ToolPriority.high.toString(), 'high');
      expect(ToolPriority.critical.toString(), 'critical');
    });
  });

  group('ResourceUsage', () {
    test('defaults are all low', () {
      const usage = ResourceUsage();
      expect(usage.toJson(), {
        'cpu': 'low',
        'memory': 'low',
        'network': 'low',
        'disk': 'low',
      });
    });

    test('toJson / fromJson round-trip with explicit levels', () {
      const usage =
          ResourceUsage(cpu: 'high', memory: 'medium', network: 'low', disk: 'high');
      final json = usage.toJson();
      expect(json, {
        'cpu': 'high',
        'memory': 'medium',
        'network': 'low',
        'disk': 'high',
      });
      final back = ResourceUsage.fromJson(json);
      expect(back.cpu, 'high');
      expect(back.memory, 'medium');
      expect(back.network, 'low');
      expect(back.disk, 'high');
    });

    test('fromJson defaults missing fields to low', () {
      final usage = ResourceUsage.fromJson(const {});
      expect(usage.toJson(), const ResourceUsage().toJson());
    });
  });

  group('DeprecationInfo', () {
    test('toJson omits optional fields when absent', () {
      const info = DeprecationInfo(version: '1.0.0', reason: 'superseded');
      expect(info.toJson(), {
        'version': '1.0.0',
        'reason': 'superseded',
      });
    });

    test('toJson / fromJson round-trip with all fields', () {
      const info = DeprecationInfo(
        version: '1.0.0',
        reason: 'superseded',
        replacement: 'new_tool',
        removalVersion: '2.0.0',
      );
      final json = info.toJson();
      expect(json, {
        'version': '1.0.0',
        'reason': 'superseded',
        'replacement': 'new_tool',
        'removalVersion': '2.0.0',
      });
      final back = DeprecationInfo.fromJson(json);
      expect(back.version, '1.0.0');
      expect(back.reason, 'superseded');
      expect(back.replacement, 'new_tool');
      expect(back.removalVersion, '2.0.0');
    });
  });

  group('ToolAnnotationBuilder', () {
    test('every fluent setter is reflected in build() and utils read it back',
        () {
      final annotations = ToolAnnotationUtils.builder()
          .readOnly()
          .destructive(false)
          .requiresConfirmation()
          .supportsProgress()
          .supportsCancellation()
          .estimatedDuration(120)
          .category('data')
          .priority(ToolPriority.high)
          .experimental()
          .minApiVersion('2025-06-18')
          .deprecated(const DeprecationInfo(
            version: '1.0.0',
            reason: 'old',
            replacement: 'new_tool',
          ))
          .examples(['ex1', 'ex2'])
          .requiredPermissions(['read', 'write'])
          .resourceUsage(const ResourceUsage(cpu: 'high'))
          .custom('com.example/flag', true)
          .build();

      expect(ToolAnnotationUtils.isReadOnly(annotations), isTrue);
      expect(ToolAnnotationUtils.isDestructive(annotations), isFalse);
      expect(ToolAnnotationUtils.requiresConfirmation(annotations), isTrue);
      expect(ToolAnnotationUtils.supportsProgress(annotations), isTrue);
      expect(ToolAnnotationUtils.supportsCancellation(annotations), isTrue);
      expect(ToolAnnotationUtils.getEstimatedDuration(annotations), 120);
      expect(ToolAnnotationUtils.getCategory(annotations), 'data');
      expect(ToolAnnotationUtils.getPriority(annotations), ToolPriority.high);
      expect(ToolAnnotationUtils.isExperimental(annotations), isTrue);
      expect(ToolAnnotationUtils.getMinApiVersion(annotations), '2025-06-18');
      expect(ToolAnnotationUtils.isDeprecated(annotations), isTrue);
      final dep = ToolAnnotationUtils.getDeprecationInfo(annotations)!;
      expect(dep.version, '1.0.0');
      expect(dep.replacement, 'new_tool');
      expect(ToolAnnotationUtils.getExamples(annotations), ['ex1', 'ex2']);
      expect(ToolAnnotationUtils.getRequiredPermissions(annotations),
          ['read', 'write']);
      final usage = ToolAnnotationUtils.getResourceUsage(annotations)!;
      expect(usage.cpu, 'high');
      expect(annotations['com.example/flag'], isTrue);
    });

    test('build() returns an unmodifiable map', () {
      final annotations = ToolAnnotationBuilder().readOnly().build();
      expect(() => annotations['x'] = 1, throwsUnsupportedError);
    });
  });

  group('ToolAnnotationUtils on null / empty annotations', () {
    test('every boolean check defaults to false on null', () {
      expect(ToolAnnotationUtils.isReadOnly(null), isFalse);
      expect(ToolAnnotationUtils.isDestructive(null), isFalse);
      expect(ToolAnnotationUtils.requiresConfirmation(null), isFalse);
      expect(ToolAnnotationUtils.supportsProgress(null), isFalse);
      expect(ToolAnnotationUtils.supportsCancellation(null), isFalse);
      expect(ToolAnnotationUtils.isExperimental(null), isFalse);
      expect(ToolAnnotationUtils.isDeprecated(null), isFalse);
    });

    test('every getter defaults to null on null / empty annotations', () {
      expect(ToolAnnotationUtils.getEstimatedDuration(null), isNull);
      expect(ToolAnnotationUtils.getCategory(null), isNull);
      expect(ToolAnnotationUtils.getPriority(null), isNull);
      expect(ToolAnnotationUtils.getMinApiVersion(null), isNull);
      expect(ToolAnnotationUtils.getDeprecationInfo(null), isNull);
      expect(ToolAnnotationUtils.getExamples(null), isNull);
      expect(ToolAnnotationUtils.getRequiredPermissions(null), isNull);
      expect(ToolAnnotationUtils.getResourceUsage(null), isNull);
    });

    test('getEstimatedDuration returns null for a non-int value', () {
      expect(
        ToolAnnotationUtils.getEstimatedDuration(
            {ToolAnnotationKeys.estimatedDuration: 'not-an-int'}),
        isNull,
      );
    });

    test('getPriority returns null for an unrecognized priority string', () {
      expect(
        ToolAnnotationUtils.getPriority(
            {ToolAnnotationKeys.priority: 'nonsense'}),
        isNull,
      );
    });

    test('getExamples / getRequiredPermissions return null for non-list',
        () {
      expect(
        ToolAnnotationUtils.getExamples(
            {ToolAnnotationKeys.examples: 'not-a-list'}),
        isNull,
      );
      expect(
        ToolAnnotationUtils.getRequiredPermissions(
            {ToolAnnotationKeys.requiredPermissions: 'not-a-list'}),
        isNull,
      );
    });

    test('getResourceUsage returns null for a non-map value', () {
      expect(
        ToolAnnotationUtils.getResourceUsage(
            {ToolAnnotationKeys.resourceUsage: 'not-a-map'}),
        isNull,
      );
    });

    test('getDeprecationInfo returns null for a non-map value', () {
      expect(
        ToolAnnotationUtils.getDeprecationInfo(
            {ToolAnnotationKeys.deprecated: 'not-a-map'}),
        isNull,
      );
    });
  });

  group('ToolAnnotationUtils.validateAnnotations', () {
    test('no errors for a clean readOnly tool', () {
      final errors = ToolAnnotationUtils.validateAnnotations(
          {ToolAnnotationKeys.readOnly: true});
      expect(errors, isEmpty);
    });

    test('flags conflicting readOnly + destructive', () {
      final errors = ToolAnnotationUtils.validateAnnotations({
        ToolAnnotationKeys.readOnly: true,
        ToolAnnotationKeys.destructive: true,
      });
      expect(errors, contains('Tool cannot be both readOnly and destructive'));
    });

    test('accepts a valid priority string', () {
      final errors = ToolAnnotationUtils.validateAnnotations(
          {ToolAnnotationKeys.priority: 'high'});
      expect(errors, isEmpty);
    });

    test('flags an invalid priority string', () {
      final errors = ToolAnnotationUtils.validateAnnotations(
          {ToolAnnotationKeys.priority: 'urgent'});
      expect(errors, ['Invalid priority value: urgent']);
    });

    test('flags a negative estimatedDuration', () {
      final errors = ToolAnnotationUtils.validateAnnotations(
          {ToolAnnotationKeys.estimatedDuration: -5});
      expect(errors,
          ['estimatedDuration must be a non-negative integer']);
    });

    test('flags a non-int estimatedDuration', () {
      final errors = ToolAnnotationUtils.validateAnnotations(
          {ToolAnnotationKeys.estimatedDuration: 'soon'});
      expect(errors,
          ['estimatedDuration must be a non-negative integer']);
    });

    test('accepts a non-negative int estimatedDuration', () {
      final errors = ToolAnnotationUtils.validateAnnotations(
          {ToolAnnotationKeys.estimatedDuration: 30});
      expect(errors, isEmpty);
    });

    test('flags an invalid resourceUsage level', () {
      final errors = ToolAnnotationUtils.validateAnnotations({
        ToolAnnotationKeys.resourceUsage: {'cpu': 'extreme'},
      });
      expect(
        errors,
        ['Invalid cpu usage level: extreme. Must be one of [low, medium, high]'],
      );
    });

    test('accepts a valid resourceUsage map', () {
      final errors = ToolAnnotationUtils.validateAnnotations({
        ToolAnnotationKeys.resourceUsage: {
          'cpu': 'high',
          'memory': 'low',
          'network': 'medium',
          'disk': 'low',
        },
      });
      expect(errors, isEmpty);
    });

    test('multiple violations are all reported', () {
      final errors = ToolAnnotationUtils.validateAnnotations({
        ToolAnnotationKeys.readOnly: true,
        ToolAnnotationKeys.destructive: true,
        ToolAnnotationKeys.priority: 'bogus',
        ToolAnnotationKeys.estimatedDuration: -1,
      });
      expect(errors, hasLength(3));
    });
  });

  group('ToolAnnotationPresets', () {
    test('readOnlyTool defaults', () {
      final annotations = ToolAnnotationPresets.readOnlyTool();
      expect(ToolAnnotationUtils.isReadOnly(annotations), isTrue);
      expect(ToolAnnotationUtils.getCategory(annotations), 'data');
      expect(ToolAnnotationUtils.getPriority(annotations), ToolPriority.normal);
    });

    test('readOnlyTool with overrides', () {
      final annotations = ToolAnnotationPresets.readOnlyTool(
          category: 'analytics', priority: ToolPriority.low);
      expect(ToolAnnotationUtils.getCategory(annotations), 'analytics');
      expect(ToolAnnotationUtils.getPriority(annotations), ToolPriority.low);
    });

    test('destructiveTool defaults require confirmation and are high priority',
        () {
      final annotations = ToolAnnotationPresets.destructiveTool();
      expect(ToolAnnotationUtils.isDestructive(annotations), isTrue);
      expect(ToolAnnotationUtils.requiresConfirmation(annotations), isTrue);
      expect(ToolAnnotationUtils.getCategory(annotations), 'system');
      expect(ToolAnnotationUtils.getPriority(annotations), ToolPriority.high);
    });

    test('destructiveTool with overrides', () {
      final annotations = ToolAnnotationPresets.destructiveTool(
          category: 'db', priority: ToolPriority.critical);
      expect(ToolAnnotationUtils.getCategory(annotations), 'db');
      expect(ToolAnnotationUtils.getPriority(annotations), ToolPriority.critical);
    });

    test('longRunningTool defaults to 300s and supports progress/cancel', () {
      final annotations = ToolAnnotationPresets.longRunningTool();
      expect(ToolAnnotationUtils.supportsProgress(annotations), isTrue);
      expect(ToolAnnotationUtils.supportsCancellation(annotations), isTrue);
      expect(ToolAnnotationUtils.getEstimatedDuration(annotations), 300);
      expect(ToolAnnotationUtils.getCategory(annotations), 'processing');
    });

    test('longRunningTool with overrides', () {
      final annotations = ToolAnnotationPresets.longRunningTool(
          estimatedDuration: 60, category: 'batch');
      expect(ToolAnnotationUtils.getEstimatedDuration(annotations), 60);
      expect(ToolAnnotationUtils.getCategory(annotations), 'batch');
    });

    test('experimentalTool defaults', () {
      final annotations = ToolAnnotationPresets.experimentalTool();
      expect(ToolAnnotationUtils.isExperimental(annotations), isTrue);
      expect(ToolAnnotationUtils.getMinApiVersion(annotations), '2025-03-26');
      expect(ToolAnnotationUtils.getPriority(annotations), ToolPriority.low);
    });

    test('experimentalTool with override', () {
      final annotations =
          ToolAnnotationPresets.experimentalTool(minApiVersion: '2025-11-25');
      expect(ToolAnnotationUtils.getMinApiVersion(annotations), '2025-11-25');
    });

    test('heavyTool sets high cpu/memory usage, progress, cancel, duration',
        () {
      final annotations = ToolAnnotationPresets.heavyTool();
      final usage = ToolAnnotationUtils.getResourceUsage(annotations)!;
      expect(usage.cpu, 'high');
      expect(usage.memory, 'high');
      expect(ToolAnnotationUtils.supportsProgress(annotations), isTrue);
      expect(ToolAnnotationUtils.supportsCancellation(annotations), isTrue);
      expect(ToolAnnotationUtils.getEstimatedDuration(annotations), 600);
    });
  });

  group('ToolAnnotationKeys', () {
    test('key constants match the MCP 2025-03-26 spec names', () {
      expect(ToolAnnotationKeys.readOnly, 'readOnly');
      expect(ToolAnnotationKeys.destructive, 'destructive');
      expect(ToolAnnotationKeys.requiresConfirmation, 'requiresConfirmation');
      expect(ToolAnnotationKeys.supportsProgress, 'supportsProgress');
      expect(ToolAnnotationKeys.supportsCancellation, 'supportsCancellation');
      expect(ToolAnnotationKeys.estimatedDuration, 'estimatedDuration');
      expect(ToolAnnotationKeys.category, 'category');
      expect(ToolAnnotationKeys.priority, 'priority');
      expect(ToolAnnotationKeys.experimental, 'experimental');
      expect(ToolAnnotationKeys.minApiVersion, 'minApiVersion');
      expect(ToolAnnotationKeys.deprecated, 'deprecated');
      expect(ToolAnnotationKeys.examples, 'examples');
      expect(ToolAnnotationKeys.requiredPermissions, 'requiredPermissions');
      expect(ToolAnnotationKeys.resourceUsage, 'resourceUsage');
    });
  });
}
