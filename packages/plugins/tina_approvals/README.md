# Approval plugins

`ApprovalsPlugin` is the runtime plugin `tina/approvals`. It owns pending
requests, unique IDs, expiry and cancellation. `ApprovalRequester` is what a
sandbox or other policy boundary receives. The caller owns enforcement and
remembered grants; approval delivery never executes an operation.

`ApprovalChannel` is the delivery interface. A channel receives an
`ApprovalTicket` containing an immutable `ApprovalRequest` (ID, operation,
target, reason). It calls `ticket.respond(decision)` to resolve it. That method
returns false after cancellation, expiry, shutdown or an earlier decision.
`ticket.done` signals both answers and invalidation so a channel can dismiss
UI, cancel a key read, or remove remote correlation state. Delivery exceptions
deny. A delivery returning normally without an answer leaves the ticket pending.

There is no timeout by default: human approvals wait for a response or explicit
cancellation. Embedders can opt into expiry with the plugin constructor's
`timeout` argument.
Pending requests are session-local and not restored from persistence. Turn
cancellation is observed through the generic `TurnContext.whenCancelled`
contract; no engine code imports approval or UI types.

## Registration

The host's `PluginRegistry` resolves typed capabilities at construction time.
Factories receive their declared dependencies as arguments. There is no global
service lookup available to running plugins.

- `approvalsDefinition<C>()` requires `approvalChannel` and provides
  `approvalRequester`.
- The tools package's `toolsDefinition<C>()` requires `approvalRequester` and
  adapts it to the sandbox's existing `Approver` interface.
- `approvalTuiDefinition<C>()` supplies the TUI channel. The plugin implements
  `ConsoleContribution`; the frontend generically attaches, repaints and
  detaches it using the console toolkit. It imports neither tina_tui nor tools.

For an embedding application, register an alternate channel:

```dart
final channel = StreamApprovalChannel(id: 'acme/messages');
registry.registerDefinition(PluginDefinition<MyContext>(
  channel.id,
  (_) => channel,
  provides: [approvalChannel],
));
```

The application config selects it:

```toml
[plugins]
approval_channel = "acme/messages"
```

The catalog only allows its trusted constructor to register `tina/` IDs.
Unknown IDs, missing or competing capability providers and dependency cycles
fail before factories run. Actual provider types and plugin identities are
checked when constructing the graph. Failed construction cleans up previously
constructed plugins.

## Stream and remote transports

`StreamApprovalChannel` provides one request stream subscription and a
`respond(id, decision)` method. Requests without a subscriber are denied;
unsubscribing denies outstanding requests. Unknown, duplicate and stale IDs
return false. This adapter is in-memory and opens no network connections.

An SMS/web adapter sends each request, stores the transport-message-to-request-ID
mapping, authenticates incoming responders, and only then calls `respond`.
IDs identify requests; they do not authenticate a person. Treat successful
message delivery as pending, never as consent. Expired messages cannot authorize
later operations. An actual SMS provider integration is not included.

Run `dart test` here for correlation, failure, disconnect, expiry and turn
cancellation checks. The TUI suite additionally executes real sandbox writes
through an independently registered channel and verifies cancelled requests
cannot write after a late reply.
