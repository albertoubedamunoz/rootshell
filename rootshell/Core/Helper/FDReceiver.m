//
//  FDReceiver.m
//  rootshell
//
//  Implementation for receiving file descriptors via Unix sockets
//

#import "FDReceiver.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <unistd.h>
#import <os/log.h>

static os_log_t fd_receiver_log(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.kk2.rootshell", "ghostty");
    });
    return log;
}

@implementation FDReceiverImpl

+ (int)receiveFileDescriptorAsServer:(NSString *)socketPath
                               error:(NSError **)error {
    os_log_info(fd_receiver_log(), "FD receiver: creating server socket at %{public}@", socketPath);

    // Create socket
    int serverSock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (serverSock < 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to create socket"
            }];
        }
        return -1;
    }

    // Bind to socket path
    const char *path = [socketPath UTF8String];
    unlink(path);  // Remove existing socket if present

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    if (bind(serverSock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        int bindErrno = errno;
        close(serverSock);
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:bindErrno
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to bind socket"
            }];
        }
        return -1;
    }

    // Owner-only: both peers run as the same uid
    chmod(path, 0600);

    // Listen for connections
    if (listen(serverSock, 1) < 0) {
        int listenErrno = errno;
        close(serverSock);
        unlink(path);
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:listenErrno
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to listen on socket"
            }];
        }
        return -1;
    }

    os_log_info(fd_receiver_log(), "FD receiver: listening on %{public}@, waiting for helper to connect...", socketPath);

    // Verify socket file exists (for debugging)
    if (access(path, F_OK) == 0) {
        os_log_info(fd_receiver_log(), "FD receiver: Socket file verified to exist");
    } else {
        os_log_error(fd_receiver_log(), "FD receiver: WARNING: Socket file does NOT exist");
    }

    // Use select() to wait for connection with proper timeout
    // SO_RCVTIMEO doesn't work for accept(), so we need select()
    fd_set readfds;
    FD_ZERO(&readfds);
    FD_SET(serverSock, &readfds);

    struct timeval tv;
    tv.tv_sec = 10;
    tv.tv_usec = 0;

    int selectResult = select(serverSock + 1, &readfds, NULL, NULL, &tv);
    if (selectResult < 0) {
        int selectErrno = errno;
        close(serverSock);
        unlink(path);
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:selectErrno
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"select() failed while waiting for helper"
            }];
        }
        return -1;
    } else if (selectResult == 0) {
        // Timeout
        close(serverSock);
        unlink(path);
        if (error) {
            *error = [NSError errorWithDomain:@"FDReceiver"
                                         code:ETIMEDOUT
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Timeout waiting for helper to connect"
            }];
        }
        os_log_error(fd_receiver_log(), "FD receiver: Timeout waiting for helper connection");
        return -1;
    }

    // Now accept() should return immediately since select() indicated readiness
    int clientSock = accept(serverSock, NULL, NULL);
    if (clientSock < 0) {
        int acceptErrno = errno;
        close(serverSock);
        unlink(path);
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:acceptErrno
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to accept connection from helper"
            }];
        }
        return -1;
    }

    os_log_info(fd_receiver_log(), "FD receiver: helper connected, receiving FD...");

    // Receive the file descriptor
    int receivedFD = [self receiveFileDescriptor:clientSock error:error];

    // Cleanup
    close(clientSock);
    close(serverSock);
    unlink(path);

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
            *error = [NSError errorWithDomain:@"FDReceiver"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"No file descriptor in message"
            }];
        }
        return -1;
    }

    int fd;
    memcpy(&fd, CMSG_DATA(cmsg), sizeof(int));

    os_log_info(fd_receiver_log(), "Successfully received FD %d via socket", fd);
    return fd;
}

@end
