//
//  GitSSHTransportBridge.h
//  rootshell
//
//  C bridge for libgit2 custom SSH smart subtransport.
//  Defines extended structs and registers transport with libgit2.
//

#ifndef GitSSHTransportBridge_h
#define GitSSHTransportBridge_h

#include <TargetConditionals.h>

#if !TARGET_OS_MACCATALYST

/// Register the custom SSH smart subtransport with libgit2.
/// Must be called after git_libgit2_init().
/// Returns 0 on success, non-zero on error.
int git_ssh_custom_transport_register(void);

#endif /* !TARGET_OS_MACCATALYST */

#endif /* GitSSHTransportBridge_h */
