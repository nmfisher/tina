/// Source of completion suggestions for an interactive picker/editor. The
/// consumer calls [complete] each time the picker's query changes —
/// implementations should cache any expensive enumeration (e.g., file walks).
abstract class CompletionProvider {
  Future<List<String>> complete(String query);
}
