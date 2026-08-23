//
//  FDPassingServer.m
//  rootshell-helper
//
//  Unix domain socket implementation for FD passing
//

#import "FDPassingServer.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <unistd.h>

@implementation FDPassingServerImpl

+ (BOOL)sendFileDescriptor:(int)fd
            toSocketAtPath:(NSString *)socketPath
                     error:(NSError **)error {
    NSLog(@"FD sender: connecting to socket at %@", socketPath);

    // Retry settings - the Catalyst app may not be listening yet
    // due to race condition between response delivery and socket setup
    const int maxRetries = 20;
    const useconds_t retryDelayMicros = 100000;  // 100ms between retries

    // Connect to server (created by Catalyst app)
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    const char *path = [socketPath UTF8String];
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    int sock = -1;
    int lastErrno = 0;

    for (int attempt = 0; attempt < maxRetries; attempt++) {
        // Create socket (fresh for each attempt)
        sock = socket(AF_UNIX, SOCK_STREAM, 0);
        if (sock < 0) {
            if (error) {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                             code:errno
                                         userInfo:@{
                    NSLocalizedDescriptionKey: @"Failed to create socket"
                }];
            }
            return NO;
        }

        // Set timeout for connect
        struct timeval tv;
        tv.tv_sec = 5;
        tv.tv_usec = 0;
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            // Success!
            NSLog(@"FD sender: connected to %@ on attempt %d", socketPath, attempt + 1);
            break;
        }

        lastErrno = errno;
        close(sock);
        sock = -1;

        // Only retry for transient errors (ENOENT = socket doesn't exist yet, ECONNREFUSED = not listening)
        if (lastErrno != ENOENT && lastErrno != ECONNREFUSED) {
            break;  // Non-retryable error
        }

        if (attempt < maxRetries - 1) {
            NSLog(@"FD sender: connect attempt %d failed (errno=%d), retrying in %dms...",
                  attempt + 1, lastErrno, retryDelayMicros / 1000);
            usleep(retryDelayMicros);
        }
    }

    if (sock < 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:lastErrno
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to connect to socket after retries",
                NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:@"Socket path: %@, errno: %d", socketPath, lastErrno]
            }];
        }
        return NO;
    }

    // Send the file descriptor via SCM_RIGHTS
    BOOL success = [self sendFileDescriptorData:fd viaSocket:sock error:error];

    close(sock);
    return success;
}

+ (BOOL)sendFileDescriptorData:(int)fd viaSocket:(int)sock error:(NSError **)error {
    // Prepare message with SCM_RIGHTS ancillary data
    struct msghdr msg;
    struct iovec iov[1];
    char cmsgbuf[CMSG_SPACE(sizeof(int))];
    char dummy = 'X';  // Dummy byte to send

    // Setup IO vector with dummy byte
    iov[0].iov_base = &dummy;
    iov[0].iov_len = 1;

    // Setup message header
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsgbuf;
    msg.msg_controllen = sizeof(cmsgbuf);

    // Setup control message with SCM_RIGHTS
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));

    // Copy FD into control message
    memcpy(CMSG_DATA(cmsg), &fd, sizeof(int));

    // Send the message
    ssize_t sent = sendmsg(sock, &msg, 0);
    if (sent < 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to send file descriptor"
            }];
        }
        return NO;
    }

    NSLog(@"Successfully sent FD %d via socket", fd);
    return YES;
}

+ (int)receiveFileDescriptorFromSocket:(NSString *)socketPath
                                 error:(NSError **)error {
    // Create socket
    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to create socket"
            }];
        }
        return -1;
    }

    // Connect to server
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    const char *path = [socketPath UTF8String];
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    // Set timeout for connect
    struct timeval tv;
    tv.tv_sec = 10;
    tv.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(sock);
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to connect to socket",
                NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:@"Socket path: %@", socketPath]
            }];
        }
        return -1;
    }

    NSLog(@"FD receiver: connected to %@", socketPath);

    // Receive the file descriptor
    int receivedFD = [self receiveFileDescriptor:sock error:error];

    close(sock);

    return receivedFD;
}

+ (int)receiveFileDescriptor:(int)sock error:(NSError **)error {
    struct msghdr msg;
    struct iovec iov[1];
    char cmsgbuf[CMSG_SPACE(sizeof(int))];
    char dummy;

    // Setup IO vector
    iov[0].iov_base = &dummy;
    iov[0].iov_len = 1;

    // Setup message header
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsgbuf;
    msg.msg_controllen = sizeof(cmsgbuf);

    // Receive the message
    ssize_t received = recvmsg(sock, &msg, 0);
    if (received < 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to receive message"
            }];
        }
        return -1;
    }

    // Extract file descriptor from control message
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    if (!cmsg || cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS) {
        if (error) {
            *error = [NSError errorWithDomain:@"FDPassingServer"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"No file descriptor in message"
            }];
        }
        return -1;
    }

    int fd;
    memcpy(&fd, CMSG_DATA(cmsg), sizeof(int));

    NSLog(@"Successfully received FD %d via socket", fd);
    return fd;
}

@end
