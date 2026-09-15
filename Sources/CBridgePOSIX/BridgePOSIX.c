#define _GNU_SOURCE
#include "BridgePOSIX.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>

int bridge_prepare_reaping(void) {
    struct sigaction action = {0};
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    return sigaction(SIGCHLD, &action, NULL);
}

int bridge_pipe(int descriptors[2]) {
#ifdef __linux__
    // Atomic CLOEXEC prevents leakage into concurrent launches.
    return pipe2(descriptors, O_CLOEXEC);
#else
    // Darwin launches use POSIX_SPAWN_CLOEXEC_DEFAULT.
    return pipe(descriptors);
#endif
}

int bridge_spawn_closefrom(posix_spawn_file_actions_t *actions) {
#ifdef __linux__
    // glibc >= 2.34. Applied after dup2, so only standard I/O is inherited.
    return posix_spawn_file_actions_addclosefrom_np(actions, 3);
#else
    (void)actions;
    return 0;
#endif
}

ssize_t bridge_write(int fd, const void *bytes, size_t count) {
#ifdef __linux__
    // Block SIGPIPE only on this thread, without changing daemon-wide signal
    // policy or the disposition inherited by backend children.
    sigset_t blocked, previous, pending;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGPIPE);
    int error = pthread_sigmask(SIG_BLOCK, &blocked, &previous);
    if (error != 0) { errno = error; return -1; }
    if (sigpending(&pending) != 0) {
        int saved = errno;
        pthread_sigmask(SIG_SETMASK, &previous, NULL);
        errno = saved;
        return -1;
    }
    int already_pending = sigismember(&pending, SIGPIPE);
    ssize_t result = write(fd, bytes, count);
    int saved = errno;
    if (result < 0 && saved == EPIPE && !already_pending) {
        struct timespec zero = {0, 0};
        while (sigtimedwait(&blocked, NULL, &zero) < 0 && errno == EINTR) {}
    }
    pthread_sigmask(SIG_SETMASK, &previous, NULL);
    errno = saved;
    return result;
#else
    // The pipe has F_SETNOSIGPIPE on Darwin.
    return write(fd, bytes, count);
#endif
}
