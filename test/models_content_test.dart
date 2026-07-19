/// Pure-logic coverage for the `Content` hierarchy in
/// `lib/src/models/models.dart` — `Content.fromJson` dispatch (including the
/// unknown-type throw), and `toJson`/`fromJson` round-trips for
/// `TextContent`, `ImageContent`, `AudioContent`, `ResourceContent`, and
/// `ResourceLinkContent`.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:mcp_server/mcp_server.dart';

void main() {
  group('Content.fromJson dispatch', () {
    test('dispatches to TextContent for type "text"', () {
      final c = Content.fromJson({'type': 'text', 'text': 'hi'});
      expect(c, isA<TextContent>());
      expect((c as TextContent).text, 'hi');
    });

    test('dispatches to ImageContent for type "image"', () {
      final c = Content.fromJson(
          {'type': 'image', 'data': 'YWJj', 'mimeType': 'image/png'});
      expect(c, isA<ImageContent>());
    });

    test('dispatches to AudioContent for type "audio"', () {
      final c = Content.fromJson(
          {'type': 'audio', 'data': 'YWJj', 'mimeType': 'audio/wav'});
      expect(c, isA<AudioContent>());
    });

    test('dispatches to ResourceContent for type "resource"', () {
      final c = Content.fromJson({
        'type': 'resource',
        'resource': {'uri': 'file:///a.txt'},
      });
      expect(c, isA<ResourceContent>());
    });

    test('dispatches to ResourceLinkContent for type "resource_link"', () {
      final c = Content.fromJson(
          {'type': 'resource_link', 'uri': 'file:///a.txt'});
      expect(c, isA<ResourceLinkContent>());
    });

    test('throws ArgumentError for an unknown type', () {
      expect(() => Content.fromJson({'type': 'video'}),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('TextContent', () {
    test('toJson without annotations', () {
      const c = TextContent(text: 'hello');
      expect(c.toJson(), {'type': 'text', 'text': 'hello'});
    });

    test('toJson with annotations, fromJson round-trip', () {
      const c = TextContent(text: 'hi', annotations: {'priority': 1});
      final json = c.toJson();
      expect(json['annotations'], {'priority': 1});
      final back = TextContent.fromJson(json);
      expect(back.text, 'hi');
      expect(back.annotations, {'priority': 1});
    });
  });

  group('ImageContent', () {
    test('requires either url or data', () {
      expect(() => ImageContent(mimeType: 'image/png'),
          throwsA(isA<AssertionError>()));
    });

    test('fromBase64 factory produces a data-backed instance', () {
      final c = ImageContent.fromBase64(
          base64Data: 'ZGF0YQ==', mimeType: 'image/png');
      expect(c.data, 'ZGF0YQ==');
      expect(c.url, isNull);
      expect(c.mimeType, 'image/png');
    });

    test('toJson prefers data over url when both are set', () {
      const c = ImageContent(
        url: 'https://example.com/img.png',
        data: 'ZGF0YQ==',
        mimeType: 'image/png',
      );
      final json = c.toJson();
      expect(json['data'], 'ZGF0YQ==');
      expect(json.containsKey('url'), isFalse);
    });

    test('toJson falls back to url when data is absent', () {
      const c = ImageContent(
        url: 'https://example.com/img.png',
        mimeType: 'image/png',
      );
      final json = c.toJson();
      expect(json['url'], 'https://example.com/img.png');
      expect(json.containsKey('data'), isFalse);
    });

    test('toJson includes annotations when present', () {
      const c = ImageContent(
        data: 'ZGF0YQ==',
        mimeType: 'image/png',
        annotations: {'alt': 'a cat'},
      );
      expect(c.toJson()['annotations'], {'alt': 'a cat'});
    });

    test('fromJson round-trip with url only', () {
      final json = {
        'type': 'image',
        'url': 'https://example.com/x.png',
        'mimeType': 'image/png',
      };
      final back = ImageContent.fromJson(json);
      expect(back.url, 'https://example.com/x.png');
      expect(back.data, isNull);
      expect(back.mimeType, 'image/png');
    });
  });

  group('AudioContent', () {
    test('toJson without annotations', () {
      const c = AudioContent(data: 'YWJj', mimeType: 'audio/wav');
      expect(c.toJson(), {
        'type': 'audio',
        'data': 'YWJj',
        'mimeType': 'audio/wav',
      });
    });

    test('toJson with annotations, fromJson round-trip', () {
      const c = AudioContent(
        data: 'YWJj',
        mimeType: 'audio/wav',
        annotations: {'duration': 5},
      );
      final json = c.toJson();
      expect(json['annotations'], {'duration': 5});
      final back = AudioContent.fromJson(json);
      expect(back.data, 'YWJj');
      expect(back.mimeType, 'audio/wav');
      expect(back.annotations, {'duration': 5});
    });
  });

  group('ResourceContent', () {
    test('toJson with text only', () {
      const c = ResourceContent(uri: 'file:///a.txt', text: 'contents');
      final json = c.toJson();
      expect(json['type'], 'resource');
      expect(json['resource'], {'uri': 'file:///a.txt', 'text': 'contents'});
    });

    test('toJson with blob, mimeType, and annotations', () {
      const c = ResourceContent(
        uri: 'file:///a.bin',
        blob: 'YmluYXJ5',
        mimeType: 'application/octet-stream',
        annotations: {'audience': 'user'},
      );
      final json = c.toJson();
      expect(json['resource'], {
        'uri': 'file:///a.bin',
        'blob': 'YmluYXJ5',
        'mimeType': 'application/octet-stream',
      });
      expect(json['annotations'], {'audience': 'user'});
    });

    test('fromJson round-trip', () {
      final json = {
        'type': 'resource',
        'resource': {
          'uri': 'file:///a.txt',
          'text': 'hi',
          'mimeType': 'text/plain',
        },
        'annotations': {'x': 1},
      };
      final back = ResourceContent.fromJson(json);
      expect(back.uri, 'file:///a.txt');
      expect(back.text, 'hi');
      expect(back.mimeType, 'text/plain');
      expect(back.blob, isNull);
      expect(back.annotations, {'x': 1});
    });
  });

  group('ResourceLinkContent', () {
    test('toJson with uri only', () {
      const c = ResourceLinkContent(uri: 'file:///a.txt');
      expect(c.toJson(), {'type': 'resource_link', 'uri': 'file:///a.txt'});
    });

    test('toJson with every optional field', () {
      const c = ResourceLinkContent(
        uri: 'file:///a.txt',
        name: 'a',
        description: 'desc',
        mimeType: 'text/plain',
        annotations: {'x': 1},
        meta: {'io.example/y': 2},
      );
      final json = c.toJson();
      expect(json['name'], 'a');
      expect(json['description'], 'desc');
      expect(json['mimeType'], 'text/plain');
      expect(json['annotations'], {'x': 1});
      expect(json['_meta'], {'io.example/y': 2});
    });

    test('fromJson round-trip', () {
      final json = {
        'type': 'resource_link',
        'uri': 'file:///a.txt',
        'name': 'a',
        'description': 'desc',
        'mimeType': 'text/plain',
        'annotations': {'x': 1},
        '_meta': {'io.example/y': 2},
      };
      final back = ResourceLinkContent.fromJson(json);
      expect(back.uri, 'file:///a.txt');
      expect(back.name, 'a');
      expect(back.description, 'desc');
      expect(back.mimeType, 'text/plain');
      expect(back.annotations, {'x': 1});
      expect(back.meta, {'io.example/y': 2});
      expect(back.toJson(), json);
    });
  });
}
