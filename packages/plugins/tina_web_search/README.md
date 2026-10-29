# tina_web_search

One model-callable tool, `web_search`: a query in, bounded formatted
results out. The plugin owns nothing about *which* search service runs —
that is the [SearchBackend](lib/src/backend.dart) seam, and the host hands
one in. The shipped backend is the Brave Search API
([brave_backend.dart](lib/src/brave_backend.dart)); a SearXNG instance,
a provider-native search API, or a test fake is another class on the same
seam.

## The three boundaries

| boundary | where it lives | contract |
|---|---|---|
| network | `tina_llm`'s `HttpEndpoint` | the same injectable client the provider wires use; tests replay recorded bytes, nothing opens a socket |
| permission | the plugin's `authorize` callback | the host wires it to the session's approval flow; the tool awaits it with the backend's concrete host *before* the backend runs, and a false becomes the call's error result |
| rendering | `WebSearchPlugin.search` | validation → authorization → backend → rendered `[1] title / url / snippet` lines, count clamped 1–20 |

Refusals and backend failures are ordinary error results the model reads —
never exceptions across the executor boundary, and never plain-text
flattening (the executor registers the full `ToolResult`, so an
authorization refusal keeps its error flag).

## Host wiring

`firstPartyPlugins` builds the definition `tina/web-search`, depending on
the mode policy, default **off**: the tool is useless without
`BRAVE_SEARCH_API_KEY`, so nothing is advertised that cannot run. The
`result_count` setting (1–20, default 5) is the tool's default `count`.
`closeSession` closes the backend (releasing its HTTP client).

The plugin itself is policy-free by construction — it cannot decide
anything about permissions, only ask. This is the `read_resource` shape:
the plugin is the reader, the tool schema is its model-facing face.

## Tests

`test/web_search_test.dart` covers validation, clamping, authorization
ordering (the ask happens before the backend sees the query), zero-hit and
failing backends, the Brave wire format (query/count/key placement, non-200
surfaces, absent `web` block), and two full agent-loop turns through
`mountOn` — one approved, one refused.
