#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

/* flock belongs to the open file description, survives exec, and is released
 * by the kernel when the last inherited descriptor closes. Never unlink it. */
int main(int argc, char **argv) {
    char *end;
    long seconds;
    struct timespec start, now, pause = {0, 100000000};
    if (argc < 4) {
        fprintf(stderr, "usage: g84-lock FILE TIMEOUT COMMAND [ARG...]\n");
        return 64;
    }
    errno = 0;
    seconds = strtol(argv[2], &end, 10);
    if (errno || *end || seconds < 0 || seconds > 300) return 64;
    int fd = open(argv[1], O_CREAT | O_RDWR, 0600);
    if (fd < 0) { perror("g84-lock: open"); return 73; }
    if (clock_gettime(CLOCK_MONOTONIC, &start)) return 74;
    while (flock(fd, LOCK_EX | LOCK_NB)) {
        if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            perror("g84-lock: flock"); return 74;
        }
        if (clock_gettime(CLOCK_MONOTONIC, &now)) return 74;
        double elapsed = (double)(now.tv_sec - start.tv_sec)
            + (double)(now.tv_nsec - start.tv_nsec) / 1000000000.0;
        if (elapsed >= seconds) {
            fprintf(stderr, "g84-lock: timeout acquiring %s\n", argv[1]);
            return 75;
        }
        nanosleep(&pause, NULL);
    }
    /* Do not set FD_CLOEXEC: the command and its children must keep the lock. */
    execvp(argv[3], &argv[3]);
    perror("g84-lock: exec");
    return 126;
}
