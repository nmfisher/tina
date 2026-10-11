# tina_classification_tui

Independent classification inspectors for tina's terminal frontend. The
`classification` runtime plugin owns inference, category learning, cancellation
and bounded trace history. Each `ClassificationView` receives its read-only
`ClassificationObservation` and owns a panel's selection, expansion, scrolling,
focus, shortcuts, animation and subscriptions.

The application creates a fresh view per console attachment. Detaching a view
releases its UI resources while classification continues. Trace snapshots and
nested question/answer metadata are immutable and shared by readers.

`/classification` and `/classification hierarchy` inspect the submitting view;
F6 toggles its panel. `/classification categories` and headless commands retain
the runtime handler. View handlers do not modify the session's command registry.

Production dependencies are `classification` and `tina_console`.

Run `dart test` and `dart analyze` from this directory.
