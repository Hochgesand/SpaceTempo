// SpaceTempo's user-session safety guard. No settings files are written.
// Restores exact live symbolic hotkey states when its parent exits or closes stdin.
#include <sys/event.h>
#include <sys/types.h>
#include <signal.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef int (*SetHotKey)(int, bool);
#ifdef ST_GUARD_TEST
// Test binary never loads SkyLight or modifies the user's shortcut state.
static int mock_set(int key, bool enabled) {
    const char *path = getenv("ST_GUARD_TEST_LOG");
    if (!path) return -1;
    FILE *log = fopen(path, "a");
    if (!log) return -1;
    fprintf(log, "%d %d\n", key, enabled ? 1 : 0);
    return fclose(log);
}
#endif
static bool parse_number(const char *text, long min, long max, long *value) {
    char *end;
    errno = 0;
    long n = strtol(text, &end, 10);
    if (errno || !*text || *end || n < min || n > max) return false;
    *value = n;
    return true;
}
int main(int argc, char **argv) {
    long parent, left, right;
    if (argc != 4 || !parse_number(argv[1], 2, 2147483647L, &parent)
        || !parse_number(argv[2], 0, 1, &left) || !parse_number(argv[3], 0, 1, &right)
        || getppid() != parent) return 2;
    #ifndef ST_GUARD_TEST
    void *library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    if (!library) return 3;
    SetHotKey set = (SetHotKey)dlsym(library, "SLSSetSymbolicHotKeyEnabled");
    if (!set) return 3;
    #else
    SetHotKey set = mock_set;
    #endif
    int queue = kqueue();
    if (queue < 0) return 4;
    // Signal delivery becomes a kqueue event, allowing normal rollback on TERM/INT.
    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    struct kevent changes[4];
    EV_SET(&changes[0], (uintptr_t)parent, EVFILT_PROC, EV_ADD | EV_ENABLE, NOTE_EXIT, 0, NULL);
    EV_SET(&changes[1], STDIN_FILENO, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
    EV_SET(&changes[2], SIGTERM, EVFILT_SIGNAL, EV_ADD | EV_ENABLE, 0, 0, NULL);
    EV_SET(&changes[3], SIGINT, EVFILT_SIGNAL, EV_ADD | EV_ENABLE, 0, 0, NULL);
    if (kevent(queue, changes, 4, NULL, 0, NULL) < 0 || getppid() != parent) return 4;
    #ifdef ST_GUARD_TEST
    if (getenv("ST_GUARD_TEST_FAIL_READY")) return 4;
    #endif
    puts("READY");
    if (fflush(stdout) != 0) return 5;
    struct kevent event;
    bool restore = true;
    for (;;) {
        int result = kevent(queue, NULL, 0, &event, 1, NULL);
        if (result < 0 && errno == EINTR) continue;
        // D means the parent already restored; do not race a newer lease.
        if (result > 0 && event.filter == EVFILT_READ) {
            char command;
            if (read(STDIN_FILENO, &command, 1) == 1 && command == 'D') restore = false;
        }
        // EOF, parent exit, signal, or monitor failure restores the live state.
        break;
    }
    int first = restore ? set(79, left != 0) : 0;
    int second = restore ? set(81, right != 0) : 0;
    close(queue);
    #ifndef ST_GUARD_TEST
    dlclose(library);
    #endif
    return first == 0 && second == 0 ? 0 : 6;
}
