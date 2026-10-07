//
//  GitTailnetStream.h
//  rootshell
//
//  libgit2 socket stream that reaches tailnet hosts through in-app Tailscale.
//

#ifndef GitTailnetStream_h
#define GitTailnetStream_h

#include <TargetConditionals.h>

#if !TARGET_OS_MACCATALYST

/// Replace libgit2's plain socket stream (used under its TLS stream too).
/// Must be called after git_libgit2_init(). Returns 0 on success.
int git_tailnet_stream_register(void);

#endif /* !TARGET_OS_MACCATALYST */

#endif /* GitTailnetStream_h */
