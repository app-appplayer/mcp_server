/// Supplemental pure-logic coverage for the `ElicitationSchema` hierarchy in
/// `lib/src/models/models.dart` that isn't exercised by
/// `test/elicitation_typed_schema_test.dart` — specifically the
/// `ElicitationSchema.fromJson` dispatch branches for number/integer/boolean
/// primitives, `NumberSchema.fromJson`, `BooleanSchema.fromJson`, and the
/// `RawElicitationSchema` fallback for schema shapes this layer doesn't
/// model (e.g. object/array-of-non-enum).
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

void main() {
  group('ElicitationSchema.fromJson dispatch', () {
    test('type "number" dispatches to NumberSchema (integer: false)', () {
      final parsed = ElicitationSchema.fromJson({
        'type': 'number',
        'title': 'Price',
        'minimum': 0,
        'maximum': 100,
        'default': 9.5,
      });
      expect(parsed, isA<NumberSchema>());
      final n = parsed as NumberSchema;
      expect(n.integer, isFalse);
      expect(n.title, 'Price');
      expect(n.minimum, 0);
      expect(n.maximum, 100);
      expect(n.defaultValue, 9.5);
      expect(parsed.toJson(), {
        'type': 'number',
        'title': 'Price',
        'minimum': 0,
        'maximum': 100,
        'default': 9.5,
      });
    });

    test('type "integer" dispatches to NumberSchema (integer: true)', () {
      final parsed = ElicitationSchema.fromJson({
        'type': 'integer',
        'description': 'count',
      });
      expect(parsed, isA<NumberSchema>());
      final n = parsed as NumberSchema;
      expect(n.integer, isTrue);
      expect(n.minimum, isNull);
      expect(n.maximum, isNull);
      expect(n.defaultValue, isNull);
    });

    test('type "boolean" dispatches to BooleanSchema', () {
      final parsed = ElicitationSchema.fromJson({
        'type': 'boolean',
        'title': 'Subscribe',
        'description': 'newsletter opt-in',
        'default': false,
      });
      expect(parsed, isA<BooleanSchema>());
      final b = parsed as BooleanSchema;
      expect(b.title, 'Subscribe');
      expect(b.description, 'newsletter opt-in');
      expect(b.defaultValue, isFalse);
      expect(parsed.toJson(), {
        'type': 'boolean',
        'title': 'Subscribe',
        'description': 'newsletter opt-in',
        'default': false,
      });
    });

    test('BooleanSchema.fromJson with no fields set', () {
      final b = BooleanSchema.fromJson(const {'type': 'boolean'});
      expect(b.title, isNull);
      expect(b.description, isNull);
      expect(b.defaultValue, isNull);
      expect(b.toJson(), {'type': 'boolean'});
    });

    test('array type whose items is not an enum falls back to '
        'RawElicitationSchema', () {
      final raw = {
        'type': 'array',
        'items': {'type': 'string'},
      };
      final parsed = ElicitationSchema.fromJson(raw);
      expect(parsed, isA<RawElicitationSchema>());
      expect(parsed.toJson(), raw);
    });

    test('an entirely unmodeled type ("object") falls back to '
        'RawElicitationSchema verbatim', () {
      final raw = {
        'type': 'object',
        'properties': {
          'nested': {'type': 'string'}
        },
      };
      final parsed = ElicitationSchema.fromJson(raw);
      expect(parsed, isA<RawElicitationSchema>());
      expect((parsed as RawElicitationSchema).raw, raw);
      expect(parsed.toJson(), same(parsed.raw));
    });
  });
}
