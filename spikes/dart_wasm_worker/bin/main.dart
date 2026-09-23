// Spike: a Dart fetch handler exported to JS from a dart2wasm module.
//
// `main` installs the handler on a global (`__dart_fetch`); the JS worker
// glue (worker/index.js) picks it up after instantiating the wasm module and
// forwards Workers fetch events to it.
//
// Deliberately minimal interop surface: `Request.url`/`method`, and a
// `Response` we construct via an external factory (dart2wasm compiles
// `external factory` extension-type constructors to JS `new`).
//
// Note on async: `Function.toJS` rejects `Future<T>` in the signature, so the
// exported entry is a synchronous shim returning `JSPromise` (allowed), which
// wraps the real async Dart handler. That shim is precisely the pattern a
// real tina instance would use for awaited tool/LLM calls.
import 'dart:async';
import 'dart:js_interop';

/// The JS `Request` object, narrowed to what we touch.
extension type Request._(JSObject o) implements JSObject {
  external String get url;
  external String get method;
}

/// The JS `Response` object: opaque to Dart, constructible from Dart.
extension type Response._(JSObject o) implements JSObject {
  external factory Response([JSAny? body]);
}

/// Global export slot: worker glue reads `globalThis.__dart_fetch`.
@JS('__dart_fetch')
external set _fetchHandler(JSFunction f);

/// The real handler: async Dart, awaited LLM/tool calls would live here.
Future<Response> _handler(Request request, JSObject env, JSObject ctx) async {
  final body = 'Hello from Dart (dart2wasm) inside Cloudflare Workers!\n'
      'method: ${request.method}\n'
      'url:    ${request.url}\n';
  return Response(body.toJS);
}

/// Sync export shim: `toJS` needs JS-safe types in the signature, and the
/// `.toJS` extension on `Future<JSAny?>` is the sanctioned Future→Promise
/// bridge (JSPromise is the JS-safe spelling of an async result).
JSPromise _handlerShim(Request request, JSObject env, JSObject ctx) =>
    _handler(request, env, ctx).toJS;

void main() {
  _fetchHandler = _handlerShim.toJS;
}
