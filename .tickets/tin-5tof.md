---
id: tin-5tof
status: open
deps: []
links: []
created: 2026-09-29T02:16:27Z
type: feature
priority: 3
assignee: Nick Fisher
tags: [engine2, ui, plugins, backlog]
---
# Microphone/ASR input plugin and session-scoped composer capability

Deferred feature: let users dictate messages through a microphone/ASR plugin. Default interaction is record, transcribe into the originating conversation draft, then press Enter to send. Optional automatic submission can be considered later. This ticket records future work; do not begin implementation yet.

## Design

Keep capture and transcription in a plugin under packages/plugins, with no engine-loop changes. Use ConsoleContribution for recording shortcuts, status, settings controls, and attachment-owned resource cleanup. Add a generic session-scoped composer capability in tina_console, supplied by the TUI: a plugin can contribute draft text and optionally submit through the normal input queue. Bind each recording/transcription operation to the panel where it started, even if focus moves. Define draft merge/replacement behavior so delayed transcripts cannot overwrite newer typing. Submission must run normal input hooks, including Grok Guard. ASR backend (local or remote), audio capture library, platform support, and shortcuts remain design decisions. Plugin config storage is out of scope for the UI registration design. Existing contribution API is documented in docs/ui-contributions.md.

## Acceptance Criteria

A UI plugin can start/stop recording and display recording/transcription status. Transcription updates only its originating session draft and preserves newer edits according to an explicit policy. Manual Enter is the default submission path; any optional auto-send uses the ordinary session queue and input hooks. Switching or closing panels, cancelling transcription, unloading the plugin, and failed attachment release microphone/ASR resources; late results cannot affect a closed session. Permission denial and capture/transcription failures leave text input usable. Plugin settings use context.settings.registerSection. Tests cover routing, draft conflicts, cancellation/unload, and the normal input pipeline, plus a documented real-microphone smoke test on supported platforms.

