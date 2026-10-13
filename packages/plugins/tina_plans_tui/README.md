# tina_plans_tui

Console presentation of `tina_plans`. A session owns one runtime `PlansPlugin`;
each console attachment creates a `PlansView` backed by
`ConnectionPlanObservation` and its own `SessionConnection` attachment.

This package owns the plan overlay, progress/approval status line, rendering,
focus, selection, expansion, scrolling, shortcuts and view cleanup. It observes
immutable connection snapshots through a data-only `PlanObservation` contract.
The renderer cannot import the runtime plugin implementation.
Plan tools, commands, approval and durable state remain in `tina_plans`.

The application's console catalog connects the existing `tina/plans` feature
to a new view for each attachment. Detaching a view releases only its own UI
resources. The package's production dependencies are `tina_plans` and
`tina_console`, and `tina_host`.

Run `dart test` in this directory to verify rendering, independent views,
shared updates, detach and reattachment.
