/// `strictMode: false` — validate what is offered, let the rest through.
///
/// The shape this serves is common and was unreachable: an origin that is
/// public but personalizes for a signed-in caller. It enables authentication to
/// *observe* a credential, not to demand one — and before this, every visitor
/// arriving without one was refused, so turning observation on turned the
/// origin private.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:mcp_server/mcp_server.dart';
import 'package:test/test.dart';

class _Recording implements TokenValidator {
  final List<String> seen = <String>[];

  @override
  Future<AuthResult> validateToken(String token,
      {List<String>? requiredScopes}) async {
    seen.add(token);
    return const AuthResult(
      isAuthenticated: true,
      userInfo: <String, dynamic>{'sub': 'probe'},
      validatedScopes: <String>[],
    );
  }

  @override
  Future<Map<String, dynamic>> introspectToken(String token) async =>
      <String, dynamic>{'active': true};

  @override
  bool hasRequiredScopes(List<String> a, List<String> b) => true;
}

/// Starts a server and returns the port plus its validator.
Future<({int port, _Recording validator, Server server})> serve({
  required bool strict,
}) async {
  final server = McpServer.createServer(
    McpServerConfig(
      name: 'non-strict',
      version: '1.0.0',
      capabilities: ServerCapabilities.simple(tools: true, resources: true),
    ),
  );
  final validator = _Recording();
  server.enableAuthentication(validator, strictMode: strict);
  server.addResource(
    uri: 'ui://app',
    name: 'app',
    description: 'app',
    mimeType: 'application/json',
    handler: (uri, params) async => ReadResourceResult(
      contents: [
        ResourceContentInfo(
            uri: uri, mimeType: 'application/json', text: '{"type":"page"}'),
      ],
    ),
  );
  final port = 9200 + (strict ? 1 : 0);
  final transport =
      (await McpServer.createStreamableHttpTransportAsync(port)).get();
  server.connect(transport);
  return (port: port, validator: validator, server: server);
}

/// One JSON-RPC call, with or without a credential.
Future<({Map<String, dynamic> body, String? session})> call(
  int port,
  Map<String, dynamic> message, {
  String? bearer,
  String? session,
}) async {
  final client = HttpClient();
  final request =
      await client.postUrl(Uri.parse('http://localhost:$port/mcp'));
  request.headers.set('Content-Type', 'application/json');
  request.headers.set('Accept', 'application/json, text/event-stream');
  if (bearer != null) request.headers.set('Authorization', 'Bearer $bearer');
  if (session != null) request.headers.set('MCP-Session-Id', session);
  request.write(jsonEncode(message));
  final response = await request.close();
  final raw = await response.transform(utf8.decoder).join();
  client.close();
  // A streamed answer arrives as SSE; take the data line either way.
  final line = raw
      .split('\n')
      .firstWhere((l) => l.startsWith('data:') || l.startsWith('{'),
          orElse: () => raw);
  final json = line.startsWith('data:') ? line.substring(5).trim() : line;
  return (
    body: jsonDecode(json) as Map<String, dynamic>,
    session: response.headers.value('mcp-session-id'),
  );
}

/// Opens a session, then reads — which is the sequence a real client uses, and
/// the one the credential has to survive.
Future<Map<String, dynamic>> read(int port, {String? bearer}) async {
  final opened = await call(
    port,
    {
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-06-18',
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': 'probe', 'version': '1.0.0'},
      },
    },
    bearer: bearer,
  );
  if (opened.body['error'] != null) return opened.body;
  final answer = await call(
    port,
    {
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'resources/read',
      'params': {'uri': 'ui://app'},
    },
    bearer: bearer,
    session: opened.session,
  );
  return answer.body;
}

void main() {
  test('a visitor with no credential is answered', () async {
    final it = await serve(strict: false);
    addTearDown(it.server.disconnect);

    final answer = await read(it.port);

    // The refusal this replaces made "observe a credential" and "require one"
    // the same switch, so a public origin could not do the first.
    expect(answer['error'], isNull, reason: '$answer');
    expect(answer['result'], isNotNull);
    expect(it.validator.seen, isEmpty, reason: 'nothing was offered to check');
  });

  test('a credential that is offered is still validated', () async {
    final it = await serve(strict: false);
    addTearDown(it.server.disconnect);

    final answer = await read(it.port, bearer: 'token-1');

    expect(answer['error'], isNull, reason: '$answer');
    // Observing is the whole point of enabling it in this mode.
    expect(it.validator.seen, isNotEmpty);
    expect(it.validator.seen.toSet(), {'token-1'});
  });

  test('strict mode still refuses an empty-handed request', () async {
    final it = await serve(strict: true);
    addTearDown(it.server.disconnect);

    final answer = await read(it.port);

    // The default must not have moved: an origin that requires a credential
    // still requires one.
    expect(answer['error'], isNotNull);
    expect('${answer['error']}', contains('authorization'));
  });
}
