//
//  FDReceiver.h
//  rootshell
//
//  Receives file descriptors from ghostty-helper via Unix sockets
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FDReceiverImpl : NSObject

/// Creates a server socket and waits for the helper to connect and send an FD
/// This is the reversed direction: Catalyst app creates server, helper connects as client
/// - Parameters:
///   - socketPath: Path to Unix domain socket to create
///   - error: Error if operation fails
/// - Returns: The received file descriptor, or -1 on failure
+ (int)receiveFileDescriptorAsServer:(NSString *)socketPath
                               error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
