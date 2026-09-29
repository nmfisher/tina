# Grok input guard

Enable or disable `tina/grok-guard` with its checkbox in Settings → Plugins.
Choose Global or Workspace to persist the choice, or Session for this session.
The plugin is registered but opt-in, so it does not change the default app policy.

User messages containing `grok` (case-insensitive substring match) ask:

> Your message contains grok, this is a no-no. Are you sure you want to proceed?

Yes sends the unchanged message. No, Escape, channel failure or approval expiry
cancels it before it becomes a model message. It remains in the local input audit
and is never included in subsequent model requests. Each matching message asks
again; there is no permanent approval option. Slash commands are host commands,
not agent input, and are not inspected.

`GrokGuardPlugin.onInput` awaits the injected `ApprovalRequester`; the loop
supports asynchronous input hooks without knowing anything about approvals or
this policy. `tina/approvals-tui` renders confirmation requests as Yes/No. The
stream approval channel can deliver the same request through another transport.
