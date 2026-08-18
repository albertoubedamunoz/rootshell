//
//  GitSSHTransportBridge.c
//  rootshell
//
//  C implementation of libgit2 custom SSH smart subtransport.
//  Routes callbacks to Swift functions implemented via @_cdecl in GitSSHTransport.swift.
//

#include <TargetConditionals.h>

#if !TARGET_OS_MACCATALYST

#include <libgit2/git2.h>
#include <libgit2/git2/sys/transport.h>
#include <libgit2/git2/sys/errors.h>
#include "GitSSHTransportBridge.h"
#include <stdlib.h>
#include <string.h>

// -------------------------------------------------------------------
// Swift-implemented callbacks (via @_cdecl in GitSSHTransport.swift)
// -------------------------------------------------------------------
extern void *git_ssh_swift_create_subtransport_ctx(void);
extern int   git_ssh_swift_action(void *ctx, const char *url, int service);
extern int   git_ssh_swift_stream_read(void *ctx, char *buf, size_t size, size_t *bytes_read);
extern int   git_ssh_swift_stream_write(void *ctx, const char *buf, size_t len);
extern int   git_ssh_swift_subtransport_close(void *ctx);
extern void  git_ssh_swift_subtransport_free(void *ctx);

// -------------------------------------------------------------------
// Extended structs with Swift context pointer
// -------------------------------------------------------------------
typedef struct ssh_stream ssh_stream;

typedef struct {
    git_smart_subtransport parent;
    void *swift_ctx;
    ssh_stream *current_stream;  /* cached for non-RPC stream reuse */
} ssh_subtransport;

struct ssh_stream {
    git_smart_subtransport_stream parent;
    void *swift_ctx;   /* borrowed from subtransport, NOT separately retained */
};

// -------------------------------------------------------------------
// Stream callbacks
// -------------------------------------------------------------------
static int ssh_stream_read(
    git_smart_subtransport_stream *stream,
    char *buffer,
    size_t buf_size,
    size_t *bytes_read)
{
    ssh_stream *s = (ssh_stream *)stream;
    return git_ssh_swift_stream_read(s->swift_ctx, buffer, buf_size, bytes_read);
}

static int ssh_stream_write(
    git_smart_subtransport_stream *stream,
    const char *buffer,
    size_t len)
{
    ssh_stream *s = (ssh_stream *)stream;
    return git_ssh_swift_stream_write(s->swift_ctx, buffer, len);
}

static void ssh_stream_free(git_smart_subtransport_stream *stream)
{
    /*
     * The subtransport owns the stream via current_stream.
     * ssh_close handles freeing it, so just NULL the pointer here
     * to avoid double-free if libgit2 calls free on the stream directly.
     */
    ssh_stream *s = (ssh_stream *)stream;
    ssh_subtransport *t = (ssh_subtransport *)s->parent.subtransport;
    if (t->current_stream == s)
        t->current_stream = NULL;
    free(stream);
}

// -------------------------------------------------------------------
// Subtransport callbacks
// -------------------------------------------------------------------
static int ssh_action(
    git_smart_subtransport_stream **out,
    git_smart_subtransport *transport,
    const char *url,
    git_smart_service_t action)
{
    ssh_subtransport *t = (ssh_subtransport *)transport;

    int err = git_ssh_swift_action(t->swift_ctx, url, (int)action);
    if (err != 0)
        return err;

    /*
     * For non-RPC transports (rpc=0, i.e. SSH), libgit2 expects the SAME
     * stream pointer for the follow-up service (e.g. UPLOADPACK after
     * UPLOADPACK_LS). Reuse the cached stream when possible.
     */
    if (t->current_stream) {
        *out = &t->current_stream->parent;
        return 0;
    }

    /* Allocate a new stream struct. The Swift context is shared with subtransport. */
    ssh_stream *s = calloc(1, sizeof(ssh_stream));
    if (!s) return -1;

    s->parent.subtransport = transport;
    s->parent.read  = ssh_stream_read;
    s->parent.write = ssh_stream_write;
    s->parent.free  = ssh_stream_free;
    s->swift_ctx    = t->swift_ctx;

    t->current_stream = s;
    *out = &s->parent;
    return 0;
}

static int ssh_close(git_smart_subtransport *transport)
{
    ssh_subtransport *t = (ssh_subtransport *)transport;
    if (t->current_stream) {
        free(t->current_stream);
        t->current_stream = NULL;
    }
    if (t->swift_ctx)
        return git_ssh_swift_subtransport_close(t->swift_ctx);
    return 0;
}

static void ssh_free_subtransport(git_smart_subtransport *transport)
{
    ssh_subtransport *t = (ssh_subtransport *)transport;
    if (t->swift_ctx) {
        git_ssh_swift_subtransport_free(t->swift_ctx);
        t->swift_ctx = NULL;
    }
    free(t);
}

// -------------------------------------------------------------------
// Factory
// -------------------------------------------------------------------
static int ssh_factory(
    git_smart_subtransport **out,
    git_transport *owner,
    void *param)
{
    (void)owner;
    (void)param;

    ssh_subtransport *t = calloc(1, sizeof(ssh_subtransport));
    if (!t) return -1;

    t->parent.action = ssh_action;
    t->parent.close  = ssh_close;
    t->parent.free   = ssh_free_subtransport;
    t->swift_ctx     = git_ssh_swift_create_subtransport_ctx();

    if (!t->swift_ctx) {
        free(t);
        return -1;
    }

    *out = &t->parent;
    return 0;
}

// -------------------------------------------------------------------
// Registration
// -------------------------------------------------------------------
static git_smart_subtransport_definition ssh_definition = {
    ssh_factory,
    0,      /* rpc = 0: persistent connection (SSH) */
    NULL
};

int git_ssh_custom_transport_register(void)
{
    return git_transport_register("ssh", git_transport_smart, &ssh_definition);
}

#endif /* !TARGET_OS_MACCATALYST */
