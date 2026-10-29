/// The search backend seam: where a query becomes hits.
///
/// The plugin never names a search service. [SearchBackend] is one
/// interface — query in, hits out — and the host hands in whichever
/// implementation the user configured. The Brave implementation in
/// `brave_backend.dart` is the first one; a SearXNG instance, a
/// provider-native search API, or a test fake is just another class.
/// Authorization is separate and upstream: the tool asks the session's
/// approval flow about [SearchBackend.host] before the backend runs.
///
/// HTTP travels on tina_llm's [HttpEndpoint] seam — the same injectable
/// client the provider wires use, so tests replay recorded bytes and
/// nothing here opens a socket.
library;

import 'package:tina_llm/tina_llm.dart';

/// One result. `url` is the target the model may fetch next; `snippet`
/// is the backend's summary of the page, never the page itself.
final class SearchHit {
  const SearchHit({
    required this.title,
    required this.url,
    required this.snippet,
  });

  final String title;
  final String url;
  final String snippet;

  Map<String, dynamic> toJson() =>
      {'title': title, 'url': url, 'snippet': snippet};
}

/// Thrown by a backend when the service answered but refused the query —
/// the tool surfaces it as an ordinary error result.
final class SearchException implements Exception {
  const SearchException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => statusCode == null
      ? message
      : 'search failed (HTTP $statusCode): $message';
}

/// One search service: [host] names what the user is asked to approve,
/// [search] runs the query. Implementations throw [SearchException] for
/// refused queries and transport failures alike. [close] releases the
/// backend's resources (its HTTP client, if it built one); the plugin
/// calls it from `closeSession`.
abstract class SearchBackend {
  /// The network origin the backend talks to, e.g. `api.search.brave.com`.
  /// Shown in the approval prompt; not a pattern — one concrete host.
  String get host;

  Future<List<SearchHit>> search(String query, {required int count});

  void close() {}
}
