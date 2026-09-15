// pty_shim.h — native launch shim for tina's PTY backend.
//
// Contract: the whole fork-to-exec child path lives inside tina_pty_spawn.
// Everything allocatable (argv, envp, cwd strings) is materialized by the
// caller before the call; the child touches only async-signal-safe functions
// between fork and exec. All PTY/termios/ioctl constants come from platform
// headers, never hard-coded per-OS values.
#ifndef TINA_PTY_SHIM_H
#define TINA_PTY_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TinaPtySpawnRequest {
  const char* executable;   // resolved executable path
  char* const* argv;        // NUL-terminated argv, argv[0] == executable
  char* const* env;         // NUL-terminated envp
  const char* cwd;          // absolute working directory (may be NULL)
  int32_t rows;             // initial window rows  (> 0)
  int32_t cols;             // initial window columns (> 0)
} TinaPtySpawnRequest;

typedef struct TinaPtySpawnResult {
  int pid;                  // child pid, or -1 on structured failure
  int master_fd;            // PTY master fd, or -1 on structured failure
  int32_t status_fd;        // pipe carrying the child's raw wait status; the
                            // owner closes it after the exit status is read
  int32_t error;            // 0 on success, else errno of the failure
} TinaPtySpawnResult;

/// ABI version, so the Dart side can refuse a stale shim.
int tina_shim_abi_version(void);

/// Fork + exec [req->executable] on a new PTY. On success fills *out with the
/// child pid and the PTY master fd. On a structured launch failure (exec,
/// chdir, dup2) fills *out->error with the child-side errno and leaves
/// pid/master_fd at -1. Returns 0 for both of those cases (check out->error),
/// or a negative errno if the shim itself failed before fork.
int tina_pty_spawn(const TinaPtySpawnRequest* req, TinaPtySpawnResult* out);

/// Read up to len bytes; returns bytes read, 0 for "would block" (EAGAIN), or
/// -errno. Retries on EINTR.
int tina_pty_read(int fd, uint8_t* buf, int32_t len);

/// Write up to len bytes; returns bytes written (may be short), 0 for "would
/// block", or -errno. Retries on EINTR.
int tina_pty_write(int fd, const uint8_t* buf, int32_t len);

/// Close a fd, retrying on EINTR. Returns 0 or -errno.
int tina_pty_close(int fd);

/// Set the PTY window size. Returns 0 or -errno.
int tina_pty_resize(int fd, int32_t rows, int32_t cols);

/// Send a signal to the child. Returns 0 or -errno.
int tina_pty_kill(int pid, int sig);

/// Read the child's exit status relayed by the spawn-time supervisor over
/// [status_fd]. [wait_for_exit] 0 = poll (0 if not yet available), 1 = block.
/// Returns > 0 with *status set on exit, 0 if still running, -errno on error.
///
/// WHY A PIPE, NOT waitpid(): the host process (the Dart VM) spawns its own
/// children and runs a wait(-1)-style reaper that can steal and reap any
/// child first, making our own waitpid fail with ECHILD. A double-fork at
/// spawn time puts the exec'd child out of our reach on purpose: only the
/// short-lived supervisor waits on it and relays the raw status here.
int tina_pty_reap(int status_fd, int32_t* status, int32_t wait_for_exit);

/// Poll readability. Returns 1 = readable/EOF, 0 = timeout, -errno = error.
int tina_pty_poll(int fd, int32_t timeout_ms);

#ifdef __cplusplus
}
#endif

#endif /* TINA_PTY_SHIM_H */
