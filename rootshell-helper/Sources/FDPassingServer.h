//
//  FDPassingServer.h
//  rootshell-helper
//
//  Unix domain socket server for passing file descriptors via SCM_RIGHTS
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Server that passes file descriptors to clients via Unix domain sockets
/// Uses sendmsg() with SCM_RIGHTS ancillary data to pass FDs across processes
/// This works even when the client is sandboxed, as long as the FD is already open
@interface FDPassingServerImpl : NSObject

/// Connects to a server at the given socket path and sends the FD
/// The server should already be listening (created by the Catalyst app)
/// - Parameters:
///   - socketPath: Path to Unix domain socket
///   - fd: File descriptor to pass
///   - error: Error if operation fails
/// - Returns: YES on success, NO on failure
+ (BOOL)sendFileDescriptor:(int)fd
            toSocketAtPath:(NSString *)socketPath
                     error:(NSError **)error;

/// Receives a file descriptor from a socket
/// This is used by the client (Catalyst app) to receive the FD
/// - Parameters:
///   - socketPath: Path to Unix domain socket
///   - error: Error if operation fails
/// - Returns: The received file descriptor, or -1 on failure
+ (int)receiveFileDescriptorFromSocket:(NSString *)socketPath
                                 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
