/// Pure-logic coverage for `lib/src/common/result.dart` — the `Result<T, E>`
/// sealed class (`Success` / `Failure`), its instance methods, the
/// `Future<Result>` extension, and the `Results` static utility belt.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

void main() {
  group('Result.isSuccess / isFailure', () {
    test('Success reports isSuccess true, isFailure false', () {
      const r = Result<int, String>.success(1);
      expect(r.isSuccess, isTrue);
      expect(r.isFailure, isFalse);
    });

    test('Failure reports isSuccess false, isFailure true', () {
      const r = Result<int, String>.failure('boom');
      expect(r.isSuccess, isFalse);
      expect(r.isFailure, isTrue);
    });
  });

  group('successOrNull / failureOrNull', () {
    test('Success exposes the value via successOrNull, null failureOrNull',
        () {
      const r = Result<int, String>.success(42);
      expect(r.successOrNull, 42);
      expect(r.failureOrNull, isNull);
    });

    test('Failure exposes the error via failureOrNull, null successOrNull',
        () {
      const r = Result<int, String>.failure('bad');
      expect(r.successOrNull, isNull);
      expect(r.failureOrNull, 'bad');
    });
  });

  group('get()', () {
    test('Success returns the value', () {
      const r = Result<int, String>.success(7);
      expect(r.get(), 7);
    });

    test('Failure throws the error', () {
      const r = Result<int, Exception>.failure(FormatException('bad json'));
      expect(() => r.get(), throwsA(isA<FormatException>()));
    });
  });

  group('getOrElse', () {
    test('Success returns the value, ignoring the default', () {
      const r = Result<int, String>.success(5);
      expect(r.getOrElse(99), 5);
    });

    test('Failure returns the given default', () {
      const r = Result<int, String>.failure('err');
      expect(r.getOrElse(99), 99);
    });
  });

  group('map', () {
    test('Success maps the value', () {
      const r = Result<int, String>.success(3);
      final mapped = r.map((v) => v * 2);
      expect(mapped, isA<Success<int, String>>());
      expect(mapped.successOrNull, 6);
    });

    test('Failure preserves the error, mapper not called', () {
      const r = Result<int, String>.failure('err');
      var called = false;
      final mapped = r.map((v) {
        called = true;
        return v * 2;
      });
      expect(called, isFalse);
      expect(mapped.failureOrNull, 'err');
    });
  });

  group('mapError', () {
    test('Success passes the value through unchanged', () {
      const r = Result<int, String>.success(3);
      final mapped = r.mapError((e) => e.length);
      expect(mapped.successOrNull, 3);
    });

    test('Failure maps the error', () {
      const r = Result<int, String>.failure('oops');
      final mapped = r.mapError((e) => e.length);
      expect(mapped.failureOrNull, 4);
    });
  });

  group('flatMap', () {
    test('Success chains into another Result', () {
      const r = Result<int, String>.success(4);
      final chained = r.flatMap((v) => Result<String, String>.success('n=$v'));
      expect(chained.successOrNull, 'n=4');
    });

    test('Failure short-circuits, mapper not called', () {
      const r = Result<int, String>.failure('err');
      var called = false;
      final chained = r.flatMap((v) {
        called = true;
        return Result<String, String>.success('n=$v');
      });
      expect(called, isFalse);
      expect(chained.failureOrNull, 'err');
    });

    test('Success chaining into a Failure propagates the new failure', () {
      const r = Result<int, String>.success(4);
      final chained = r.flatMap((v) => Result<String, String>.failure('bad'));
      expect(chained.failureOrNull, 'bad');
    });
  });

  group('onSuccess / onFailure', () {
    test('onSuccess invokes the action for Success and returns this', () {
      const r = Result<int, String>.success(9);
      int? captured;
      final returned = r.onSuccess((v) => captured = v);
      expect(captured, 9);
      expect(identical(returned, r), isTrue);
    });

    test('onSuccess does not invoke the action for Failure', () {
      const r = Result<int, String>.failure('err');
      var called = false;
      r.onSuccess((v) => called = true);
      expect(called, isFalse);
    });

    test('onFailure invokes the action for Failure and returns this', () {
      const r = Result<int, String>.failure('err');
      String? captured;
      final returned = r.onFailure((e) => captured = e);
      expect(captured, 'err');
      expect(identical(returned, r), isTrue);
    });

    test('onFailure does not invoke the action for Success', () {
      const r = Result<int, String>.success(1);
      var called = false;
      r.onFailure((e) => called = true);
      expect(called, isFalse);
    });
  });

  group('fold', () {
    test('Success folds through onSuccess', () {
      const r = Result<int, String>.success(2);
      final out = r.fold((v) => 'ok:$v', (e) => 'err:$e');
      expect(out, 'ok:2');
    });

    test('Failure folds through onFailure', () {
      const r = Result<int, String>.failure('bad');
      final out = r.fold((v) => 'ok:$v', (e) => 'err:$e');
      expect(out, 'err:bad');
    });
  });

  group('Success / Failure equality, hashCode, toString', () {
    test('Success equality is value-based', () {
      const a = Success<int, String>(1);
      const b = Success<int, String>(1);
      const c = Success<int, String>(2);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a == c, isFalse);
      expect(identical(a, a), isTrue);
      final Object notAResult = 'not a result';
      expect(a == notAResult, isFalse);
      expect(a.toString(), 'Success(1)');
    });

    test('Failure equality is error-based', () {
      const a = Failure<int, String>('e');
      const b = Failure<int, String>('e');
      const c = Failure<int, String>('f');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a == c, isFalse);
      expect(identical(a, a), isTrue);
      final Object notAResult = 'not a result';
      expect(a == notAResult, isFalse);
      expect(a.toString(), 'Failure(e)');
    });
  });

  group('FutureResultExtensions', () {
    test('mapAsync maps a Success value asynchronously', () async {
      Future<Result<int, String>> future() async =>
          const Result.success(10);
      final mapped = await future().mapAsync((v) async => v * 3);
      expect(mapped.successOrNull, 30);
    });

    test('mapAsync preserves a Failure without invoking the mapper',
        () async {
      Future<Result<int, String>> future() async =>
          const Result.failure('bad');
      var called = false;
      final mapped = await future().mapAsync((v) async {
        called = true;
        return v * 3;
      });
      expect(called, isFalse);
      expect(mapped.failureOrNull, 'bad');
    });

    test('flatMapAsync chains a Success into another async Result',
        () async {
      Future<Result<int, String>> future() async => const Result.success(5);
      final chained = await future()
          .flatMapAsync((v) async => Result<String, String>.success('v=$v'));
      expect(chained.successOrNull, 'v=5');
    });

    test('flatMapAsync preserves a Failure without invoking the mapper',
        () async {
      Future<Result<int, String>> future() async =>
          const Result.failure('nope');
      var called = false;
      final chained = await future().flatMapAsync((v) async {
        called = true;
        return Result<String, String>.success('v=$v');
      });
      expect(called, isFalse);
      expect(chained.failureOrNull, 'nope');
    });
  });

  group('Results.fromNullable', () {
    test('non-null value becomes a Success', () {
      final r = Results.fromNullable<int>(5, 'was null');
      expect(r.successOrNull, 5);
    });

    test('null value becomes a Failure with the given error', () {
      final r = Results.fromNullable<int>(null, 'was null');
      expect(r.failureOrNull, 'was null');
    });
  });

  group('Results.catching', () {
    test('normal return becomes a Success', () {
      final r = Results.catching<int>(() => 1 + 1);
      expect(r.successOrNull, 2);
    });

    test('a thrown Exception is captured as a Failure', () {
      final r = Results.catching<int>(() => throw const FormatException('x'));
      expect(r.isFailure, isTrue);
      expect(r.failureOrNull, isA<FormatException>());
    });

    test('a thrown Error (not Exception) propagates (not caught)', () {
      expect(
        () => Results.catching<int>(() => throw StateError('fatal')),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('Results.catchingAsync', () {
    test('normal async return becomes a Success', () async {
      final r = await Results.catchingAsync<int>(() async => 21 * 2);
      expect(r.successOrNull, 42);
    });

    test('a thrown Exception in the async action is captured as a Failure',
        () async {
      final r = await Results.catchingAsync<int>(
          () async => throw const FormatException('async bad'));
      expect(r.isFailure, isTrue);
      expect(r.failureOrNull, isA<FormatException>());
    });
  });

  group('Results.combine', () {
    test('all successes combine into a Success of the value list', () {
      final r = Results.combine<int, String>([
        const Result.success(1),
        const Result.success(2),
        const Result.success(3),
      ]);
      expect(r.successOrNull, [1, 2, 3]);
    });

    test('the first failure short-circuits the combine', () {
      final r = Results.combine<int, String>([
        const Result.success(1),
        const Result.failure('bad-2'),
        const Result.failure('bad-3'),
      ]);
      expect(r.failureOrNull, 'bad-2');
    });

    test('an empty list combines into a Success of an empty list', () {
      final r = Results.combine<int, String>(const []);
      expect(r.successOrNull, isEmpty);
    });
  });
}
