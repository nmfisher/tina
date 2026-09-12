// Glue object for wasmtime_merged: the @Native bindings reference wasmtime
// symbols directly from Dart, so no C wrappers are needed. This translation
// unit exists only to give the linker a definite root for the shared library
// build (and a place for target-specific pragmas if Phase 1 ever needs them).
static void _dart_wasmtime_glue_marker(void) {}
