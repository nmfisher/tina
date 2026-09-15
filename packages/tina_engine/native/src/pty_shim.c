// tina_pty_shim.c — native launch shim for tina's PTY backend (Phase 1 of the
// interactive shell panel plan, docs/features/terminal_panel_plan.md).
//
// WHY A SHIM: the whole fork-to-exec child path must run in native code. After
// fork, a child of a multithreaded process (the Dart VM is multithreaded) may
// call only async-signal-safe functions until exec. The child below never
// returns through FFI into Dart, never allocates Dart objects, and never calls
// Dart. Everything that can fail before fork (openpty bookkeeping, argv/env
// memory, cwd path) is prepared by the caller before fork.
//
// Platform notes:
//  - posix_openpt/grantpt/unlockpt/ptsname are in libc on Linux and macOS;
//    no -lutil, no openpty, no Linux-specific ioctl literals. All PTY and
//    terminal constants come from the platform headers (termios.h, ioctl.h),
//    so this file compiles as-is on Linux x64/arm64 and macOS arm64.
//  - pipe() + fcntl(FD_CLOEXEC) rather than pipe2(): pipe2 is Linux-only.

#include "pty_shim.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#define TINA_SHIM_ABI_VERSION 1

// macOS: no ptsname_r. This wrapper is used only in the parent before fork,
// so non-async-signal-safe calls here are fine.
#if defined(__APPLE__)
static int ptsname_r(int fd, char* buf, size_t buflen) {
  char* name = ptsname(fd);
  if (name == NULL) return -1;
  if (strlen(name) >= buflen) {
    errno = ERANGE;
    return -1;
  }
  strcpy(buf, name);
  return 0;
}
#endif

static int set_cloexec(int fd) {
  int flags = fcntl(fd, F_GETFD);
  if (flags < 0) return -1;
  return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

int tina_shim_abi_version(void) { return TINA_SHIM_ABI_VERSION; }

int tina_pty_read(int fd, uint8_t* buf, int32_t len) {
  if (fd < 0 || buf == NULL || len <= 0) return -EINVAL;
  for (;;) {
    ssize_t n = read(fd, buf, (size_t)len);
    if (n >= 0) return (int32_t)n;
    if (errno == EINTR) continue;   // signal interruption: retry
    if (errno == EAGAIN || errno == EWOULDBLOCK) return 0; // would block
    return -errno;
  }
}

int tina_pty_write(int fd, const uint8_t* buf, int32_t len) {
  if (fd < 0 || (buf == NULL && len > 0) || len < 0) return -EINVAL;
  for (;;) {
    ssize_t n = write(fd, buf, (size_t)len);
    if (n >= 0) return (int32_t)n; // short write: caller loops on the rest
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
    return -errno;
  }
}

int tina_pty_close(int fd) {
  if (fd < 0) return -EBADF;
  int rc;
  do {
    rc = close(fd);
  } while (rc != 0 && errno == EINTR);
  return rc == 0 ? 0 : -errno;
}

int tina_pty_resize(int fd, int32_t rows, int32_t cols) {
  if (rows <= 0 || cols <= 0) return -EINVAL;
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_row = (unsigned short)rows;
  ws.ws_col = (unsigned short)cols;
  // TIOCSWINSZ comes from <sys/ioctl.h>: the correct value per platform; we
  // never hard-code another platform's ioctl number here.
  if (ioctl(fd, TIOCSWINSZ, &ws) != 0) return -errno;
  return 0;
}

int tina_pty_kill(int pid, int sig) {
  if (pid <= 0) return -EINVAL;
  int rc;
  do {
    rc = kill(pid, sig);
  } while (rc != 0 && errno == EINTR);
  return rc == 0 ? 0 : -errno;
}

// Returns the pid on success, -1 with *status untouched if waitpid itself
// failed. [wait_for_exit] 0 = WNOHANG poll, 1 = block until exit.
int tina_pty_waitpid(int pid, int32_t* status, int32_t wait_for_exit) {
  if (pid <= 0 || status == NULL) return -EINVAL;
  int st = 0;
  pid_t r;
  do {
    r = waitpid(pid, &st, wait_for_exit ? 0 : WNOHANG);
  } while (r < 0 && errno == EINTR);
  if (r < 0) return -errno;
  if (r == 0) return 0; // still running (WNOHANG)
  *status = st;
  return r;
}

int tina_pty_poll(int fd, int32_t timeout_ms) {
  if (fd < 0) return -EBADF;
  // poll() with a single descriptor; not async-signal-safe constraints here,
  // this runs on the worker thread only.
  struct pollfd pfd;
  pfd.fd = fd;
  pfd.events = POLLIN;
  pfd.revents = 0;
  int rc;
  do {
    rc = poll(&pfd, 1, timeout_ms);
  } while (rc < 0 && errno == EINTR);
  if (rc < 0) return -errno;
  if (rc == 0) return 0;
  if (pfd.revents & POLLNVAL) return -EBADF;
  if (pfd.revents & (POLLERR | POLLHUP)) return 1; // readable/EOF: caller reads
  return 1; // POLLIN
}

static void report_and_exit(int fd, int e) {
  ssize_t wn;
  do {
    wn = write(fd, &e, sizeof(e));
  } while (wn < 0 && errno == EINTR);
  _exit(127);
}

// Child path after fork. Only async-signal-safe calls from here to exec:
// setsid, ioctl, dup2, close, sigprocmask, signal-disposition reset, chdir,
// execve, write to an already-open fd, _exit.
static void child_exec(const TinaPtySpawnRequest* req, int slave_fd,
                       int master_fd, int err_pipe) {
  // New session: the child becomes session leader, detaching it from any
  // controlling terminal tina itself has. Never opens the developer's tty.
  if (setsid() < 0) {
    // EPERM can happen only if the child already leads a session; proceed and
    // try to steal the tty anyway.
  }

  // Make the slave the controlling terminal of the new session. TIOCSCTTY is
  // the per-platform macro from <sys/ioctl.h>.
  (void)ioctl(slave_fd, TIOCSCTTY, (char*)NULL);

  // Slave becomes stdin/stdout/stderr. Descriptor ownership from here:
  // 0/1/2 are the terminal; the master and slave originals are closed.
  if (dup2(slave_fd, 0) < 0 || dup2(slave_fd, 1) < 0 || dup2(slave_fd, 2) < 0) {
    report_and_exit(err_pipe, errno);
  }
  close(slave_fd);
  close(master_fd); // master is CLOEXEC too; close it explicitly anyway

  // Reset the signal mask and dispositions the VM may have altered.
  sigset_t empty;
  sigemptyset(&empty);
  sigprocmask(SIG_SETMASK, &empty, NULL);
  for (int s = 1; s <= 31; ++s) signal(s, SIG_DFL);

  if (req->cwd != NULL && req->cwd[0] != '\0') {
    if (chdir(req->cwd) != 0) report_and_exit(err_pipe, errno);
  }

  // execve replaces the process image; envp is the copied environment passed
  // from Dart, already materialized before fork.
  execve(req->executable, req->argv, req->env);

  // Exec failed: report errno over the CLOEXEC pipe (a successful exec closes
  // it in the child, so the parent sees EOF on success) and exit. _exit: no
  // atexit handlers from the parent's state.
  report_and_exit(err_pipe, errno);
}

int tina_pty_spawn(const TinaPtySpawnRequest* req, TinaPtySpawnResult* out) {
  if (req == NULL || out == NULL) return -EINVAL;
  memset(out, 0, sizeof(*out));
  out->master_fd = -1;
  out->pid = -1;

  if (req->executable == NULL || req->argv == NULL || req->rows <= 0 ||
      req->cols <= 0) {
    return -EINVAL;
  }

  // --- Everything below is prepared BEFORE fork. --------------------------
  int master = posix_openpt(O_RDWR | O_NOCTTY);
  if (master < 0) return -errno;
  if (grantpt(master) != 0) {
    int e = errno;
    close(master);
    return -e;
  }
  if (unlockpt(master) != 0) {
    int e = errno;
    close(master);
    return -e;
  }
  char slave_path[128];
  if (ptsname_r(master, slave_path, sizeof(slave_path)) != 0) {
    int e = errno;
    close(master);
    return -e;
  }
  int slave = open(slave_path, O_RDWR | O_NOCTTY);
  if (slave < 0) {
    int e = errno;
    close(master);
    return -e;
  }

  // Initial termios: start from the system defaults for a fresh pty, then make
  // the flags an interactive shell expects explicit (echo, line editing,
  // signals, CR/NL mapping) so behavior does not depend on host defaults.
  struct termios tio;
  if (tcgetattr(slave, &tio) == 0) {
    tio.c_iflag |= ICRNL | IXON | IMAXBEL | BRKINT;
    tio.c_oflag |= OPOST | ONLCR;
    tio.c_lflag |= ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE
                   | IEXTEN;
    tio.c_cflag |= CS8;
    tio.c_cc[VMIN] = 1;
    tio.c_cc[VTIME] = 0;
    (void)tcsetattr(slave, TCSANOW, &tio);
  }

  // Initial window size, applied on the slave side before the child execs.
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_row = (unsigned short)req->rows;
  ws.ws_col = (unsigned short)req->cols;
  (void)ioctl(slave, TIOCSWINSZ, &ws);

  // Exec-error channel: CLOEXEC so a successful exec closes it and the parent
  // reads EOF; a failed exec writes one errno into it.
  int err_pipe[2];
  if (pipe(err_pipe) != 0) {
    int e = errno;
    close(slave);
    close(master);
    return -e;
  }
  set_cloexec(err_pipe[0]);
  set_cloexec(err_pipe[1]);

  // --- fork ---------------------------------------------------------------
  pid_t pid = fork();
  if (pid < 0) {
    int e = errno;
    close(slave);
    close(master);
    close(err_pipe[0]);
    close(err_pipe[1]);
    return -e;
  }
  if (pid == 0) {
    close(err_pipe[0]);
    child_exec(req, slave, master, err_pipe[1]);
    _exit(127); // unreachable
  }

  // --- Parent -------------------------------------------------------------
  close(slave);
  close(err_pipe[1]);
  set_cloexec(master); // no PTY fd may leak into unrelated child processes

  int exec_errno = 0;
  ssize_t n;
  do {
    n = read(err_pipe[0], &exec_errno, sizeof(exec_errno));
  } while (n < 0 && errno == EINTR);
  close(err_pipe[0]);

  if (n > 0) {
    // The child failed to exec (or dup2/chdir). Reap it and report a
    // structured launch failure; the caller never gets a live fd/pid pair.
    int32_t st = 0;
    (void)tina_pty_waitpid(pid, &st, 1);
    close(master);
    out->error = exec_errno != 0 ? exec_errno : EIO;
    out->pid = -1;
    out->master_fd = -1;
    return 0; // call succeeded; *out carries the structured failure
  }
  if (n < 0) {
    int e = errno;
    (void)tina_pty_kill(pid, SIGKILL);
    (void)tina_pty_waitpid(pid, NULL, 1);
    close(master);
    return -e;
  }

  out->master_fd = master;
  out->pid = pid;
  out->error = 0;
  return 0;
}
