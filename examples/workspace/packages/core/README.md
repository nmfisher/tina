# core

The tracker domain model: an event-sourced task list. Events are facts;
`EventBus` fans them out; repositories persist and replay them.

Nothing in this package may import from sibling packages — `store`,
`reports`, and `cli` all depend on `core`, never the reverse.
