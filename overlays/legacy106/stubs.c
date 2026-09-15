/*
 * legacy106/stubs.c — libSystem symbols present on 10.9 but missing on
 * 10.6.8, linked in addition to the toolchain's MacPorts legacy-support
 * archive (which covers the post-10.9 set: clock_gettime & friends).
 *
 * arc4random_buf is NOT defined here: it lives in the legacy106 Go package
 * (overlays/legacy106/legacy106.go). Archive members are pulled whole, so a
 * pull for any one of these symbols would also drag in a duplicate
 * arc4random_buf and fail the link.
 *
 *   pthread_main_thread_np  not exported from 10.6 libSystem — real
 *                           implementation: a constructor runs on the main
 *                           thread before main(), so cache pthread_self()
 *   strnlen, dirfd          POSIX, but absent from 10.6 libSystem
 *                           (the $UNIX2003 era)
 *
 * (xpc_date_create_from_current / notify_is_valid_token are also NOT stubbed
 * here: the mavericks-golang runtime never calls them — the CC wrapper's
 * -Wl,-U allowances are exactly for those dormant imports.)
 *
 * Each function is correct on every macOS version, so defining them
 * unconditionally is safe.
 */

#include <pthread.h>
static pthread_t legacy106_main_thread;
__attribute__((constructor)) static void legacy106_cache_main_thread(void) {
    legacy106_main_thread = pthread_self();
}
pthread_t pthread_main_thread_np(void) {
    return legacy106_main_thread;
}

#include <stddef.h>
#include <errno.h>
#include <dirent.h>
#undef strnlen
#undef dirfd
size_t strnlen(const char *s, size_t maxlen) {
    const char *p = s;
    while (maxlen-- > 0 && *p) p++;
    return (size_t)(p - s);
}
int dirfd(DIR *dirp) {
    if (dirp == NULL) {
        errno = EBADF;
        return -1;
    }
    return dirp->__dd_fd;
}
