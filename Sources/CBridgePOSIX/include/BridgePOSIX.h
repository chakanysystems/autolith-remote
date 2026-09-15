#ifndef BRIDGE_POSIX_H
#define BRIDGE_POSIX_H
#include <spawn.h>
#include <sys/types.h>

int bridge_prepare_reaping(void);
int bridge_pipe(int descriptors[2]);
int bridge_spawn_closefrom(posix_spawn_file_actions_t *actions);
ssize_t bridge_write(int fd, const void *bytes, size_t count);
int bridge_lock_exclusive(int fd);
int bridge_child_running(pid_t pid);
#endif
