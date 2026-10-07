//
//  GitTailnetStream.c
//  rootshell
//
//  libgit2 socket stream: hosts on the tailnet get a socket from in-app
//  Tailscale (via Swift); every other host gets a plain TCP connection,
//  like libgit2's default stream. TLS still layers on top.
//

#include <TargetConditionals.h>

#if !TARGET_OS_MACCATALYST

#include <libgit2/git2.h>
#include <libgit2/git2/sys/stream.h>
#include <libgit2/git2/sys/errors.h>
#include "GitTailnetStream.h"
#include <errno.h>
#include <netdb.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/// Swift (@_cdecl): a connected socket over in-app Tailscale, -1 when the
/// host isn't on the tailnet, -2 when the tailnet dial failed.
extern int git_tailnet_swift_dial(const char *host, int port);

typedef struct {
    git_stream parent;
    char *host;
    char *port;
    int fd;
} tailnet_stream;

static int plain_connect(tailnet_stream *st)
{
    struct addrinfo hints, *info = NULL, *p;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int ret = getaddrinfo(st->host, st->port, &hints, &info);
    if (ret != 0) {
        git_error_set(GIT_ERROR_NET, "failed to resolve address for %s: %s", st->host, gai_strerror(ret));
        return -1;
    }
    for (p = info; p != NULL; p = p->ai_next) {
        int s = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (s < 0) continue;
        if (connect(s, p->ai_addr, p->ai_addrlen) == 0) {
            st->fd = s;
            break;
        }
        close(s);
    }
    freeaddrinfo(info);
    if (st->fd < 0) {
        git_error_set(GIT_ERROR_NET, "failed to connect to %s: %s", st->host, strerror(errno));
        return -1;
    }
    return 0;
}

static int tailnet_connect(git_stream *stream)
{
    tailnet_stream *st = (tailnet_stream *)stream;
    int fd = git_tailnet_swift_dial(st->host, atoi(st->port));
    if (fd == -2) {
        git_error_set(GIT_ERROR_NET, "failed to connect to %s over Tailscale", st->host);
        return -1;
    }
    if (fd < 0 && plain_connect(st) < 0) {
        return -1;
    }
    if (fd >= 0) {
        st->fd = fd;
    }
    int on = 1;
    setsockopt(st->fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    return 0;
}

static ssize_t tailnet_write(git_stream *stream, const char *data, size_t len, int flags)
{
    tailnet_stream *st = (tailnet_stream *)stream;
    (void)flags;
    ssize_t n;
    do {
        n = send(st->fd, data, len, 0);
    } while (n < 0 && errno == EINTR);
    if (n < 0) {
        git_error_set(GIT_ERROR_NET, "error sending data: %s", strerror(errno));
        return -1;
    }
    return n;
}

static ssize_t tailnet_read(git_stream *stream, void *data, size_t len)
{
    tailnet_stream *st = (tailnet_stream *)stream;
    ssize_t n;
    do {
        n = recv(st->fd, data, len, 0);
    } while (n < 0 && errno == EINTR);
    if (n < 0) {
        git_error_set(GIT_ERROR_NET, "error receiving data: %s", strerror(errno));
        return -1;
    }
    return n;
}

static int tailnet_close(git_stream *stream)
{
    tailnet_stream *st = (tailnet_stream *)stream;
    if (st->fd >= 0) {
        close(st->fd);
        st->fd = -1;
    }
    return 0;
}

static void tailnet_free(git_stream *stream)
{
    tailnet_stream *st = (tailnet_stream *)stream;
    tailnet_close(stream);
    free(st->host);
    free(st->port);
    free(st);
}

static int tailnet_stream_new(git_stream **out, const char *host, const char *port)
{
    tailnet_stream *st = calloc(1, sizeof(tailnet_stream));
    if (st == NULL) {
        git_error_set_oom();
        return -1;
    }
    st->host = strdup(host);
    st->port = strdup(port ? port : "80");
    if (st->host == NULL || st->port == NULL) {
        free(st->host);
        free(st->port);
        free(st);
        git_error_set_oom();
        return -1;
    }
    st->fd = -1;
    st->parent.version = GIT_STREAM_VERSION;
    st->parent.connect = tailnet_connect;
    st->parent.write = tailnet_write;
    st->parent.read = tailnet_read;
    st->parent.close = tailnet_close;
    st->parent.free = tailnet_free;
    *out = (git_stream *)st;
    return 0;
}

int git_tailnet_stream_register(void)
{
    git_stream_registration registration;
    memset(&registration, 0, sizeof(registration));
    registration.version = GIT_STREAM_VERSION;
    registration.init = tailnet_stream_new;
    return git_stream_register(GIT_STREAM_STANDARD, &registration);
}

#endif /* !TARGET_OS_MACCATALYST */
