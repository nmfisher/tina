/// tina_web_search — one model-callable tool over an injectable search
/// backend. The plugin mounts the tool; the tool validates input, asks the
/// injected authorization callback about the backend's host, and renders
/// bounded results. Nothing here opens a socket: tests replay bytes
/// through the same seam the wires use.
library;

export 'src/backend.dart';
export 'src/brave_backend.dart';
export 'src/plugin.dart';
export 'src/web_search_tool.dart';
