/*
 * 3b2line: the shell layers runs in each 630 window. It takes the next free PORTS
 * line on the 3B2 (raw TCP on 127.0.0.1:9001) and shuttles bytes between it and
 * the window's pseudo-tty, so every window is a separate 3B2 terminal line.
 *
 *   3b2line              connect a window to the 3B2
 *   3b2line -c CMD       run CMD with /bin/sh instead (layers runs startup-file
 *                        commands as "$SHELL -c CMD", and SHELL points here)
 *
 * Environment: ATT3B2_PORTS overrides host:port (default 127.0.0.1:9001).
 */
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <termios.h>
#include <unistd.h>

static struct termios saved;
static int have_saved;

static void restore(void) {
    if (have_saved) tcsetattr(0, TCSADRAIN, &saved);
}

static int dial(const char *spec) {
    char host[64] = "127.0.0.1";
    int port = 9001;
    if (spec) {
        const char *colon = strrchr(spec, ':');
        if (colon && (size_t)(colon - spec) < sizeof host) {
            memcpy(host, spec, colon - spec);
            host[colon - spec] = '\0';
            port = atoi(colon + 1);
        } else if (colon == NULL) {
            port = atoi(spec);
        }
    }
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port)};
    if (inet_pton(AF_INET, host, &a.sin_addr) != 1) return -1;
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -1;
    if (connect(s, (struct sockaddr *)&a, sizeof a) < 0) { close(s); return -1; }
    int one = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    return s;
}

static int put(int fd, const char *p, ssize_t n) {
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        p += w; n -= w;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 3 && strcmp(argv[1], "-c") == 0) {
        execl("/bin/sh", "sh", "-c", argv[2], (char *)0);
        perror("3b2line: /bin/sh");
        return 127;
    }

    const char *spec = getenv("ATT3B2_PORTS");
    int s = dial(spec);
    if (s < 0) {
        fprintf(stderr, "3b2line: cannot reach the 3B2 at %s (is it powered on?)\r\n",
                spec ? spec : "127.0.0.1:9001");
        sleep(3);
        return 1;
    }

    /* The window is a transparent wire: the 3B2's tty driver does echo and editing. */
    if (tcgetattr(0, &saved) == 0) {
        have_saved = 1;
        atexit(restore);
        struct termios raw = saved;
        cfmakeraw(&raw);
        tcsetattr(0, TCSADRAIN, &raw);
    }
    signal(SIGPIPE, SIG_IGN);

    /* Wake getty so the window opens on a login prompt. */
    put(s, "\r", 1);

    struct pollfd p[2] = {{.fd = 0, .events = POLLIN}, {.fd = s, .events = POLLIN}};
    char buf[4096];
    for (;;) {
        if (poll(p, 2, -1) < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (p[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t n = read(0, buf, sizeof buf);
            if (n <= 0 || put(s, buf, n) < 0) break;
        }
        if (p[1].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t n = read(s, buf, sizeof buf);
            if (n <= 0 || put(1, buf, n) < 0) break;
        }
    }
    return 0;
}
