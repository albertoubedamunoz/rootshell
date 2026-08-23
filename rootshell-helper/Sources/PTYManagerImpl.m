//
//  PTYManagerImpl.m
//  rootshell-helper
//
//  Low-level PTY implementation using POSIX APIs
//

#import "PTYManagerImpl.h"
#import <util.h>  // For openpty
#import <fcntl.h>
#import <unistd.h>
#import <sys/ioctl.h>
#import <termios.h>

@implementation PTYPair

- (instancetype)initWithMaster:(int)master
                         slave:(int)slave
                     slavePath:(NSString *)slavePath {
    if (self = [super init]) {
        _masterFD = master;
        _slaveFD = slave;
        _slavePath = [slavePath copy];
    }
    return self;
}

- (void)closeSlave {
    if (_slaveFD >= 0) {
        close(_slaveFD);
        _slaveFD = -1;
    }
}

- (void)close {
    if (_masterFD >= 0) {
        close(_masterFD);
        _masterFD = -1;
    }
    if (_slaveFD >= 0) {
        close(_slaveFD);
        _slaveFD = -1;
    }
}

- (void)dealloc {
    [self close];
}

@end

@implementation PTYManagerImpl

+ (nullable PTYPair *)createPTYWithSize:(PTYSize)size
                                  error:(NSError **)error {
    int master = -1, slave = -1;
    char slaveName[1024];

    // Setup winsize for openpty
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = size.rows;
    ws.ws_col = size.cols;
    ws.ws_xpixel = size.xpixel;
    ws.ws_ypixel = size.ypixel;

    // Create PTY pair
    // Based on ghostty/src/pty.zig:86-123
    int result = openpty(&master, &slave, slaveName, NULL, &ws);
    if (result != 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to create PTY",
                NSLocalizedFailureReasonErrorKey: [NSString stringWithUTF8String:strerror(errno)]
            }];
        }
        return nil;
    }

    // Set CLOEXEC on master FD (not inherited by child processes)
    // Based on ghostty/src/pty.zig:108-113
    int flags = fcntl(master, F_GETFD);
    if (flags >= 0) {
        fcntl(master, F_SETFD, flags | FD_CLOEXEC);
    }

    // Configure terminal attributes on SLAVE FD (where the shell runs)
    // This is critical for CTRL-C to work properly
    if (![self configureTerminalAttributes:slave error:error]) {
        close(master);
        close(slave);
        return nil;
    }

    NSString *slavePathStr = [NSString stringWithUTF8String:slaveName];
    return [[PTYPair alloc] initWithMaster:master
                                     slave:slave
                                 slavePath:slavePathStr];
}

+ (BOOL)configureTerminalAttributes:(int)fd
                              error:(NSError **)error {
    struct termios attrs;

    if (tcgetattr(fd, &attrs) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to get terminal attributes"
            }];
        }
        return NO;
    }

    // Configure local flags (c_lflag)
    // ISIG: Enable signal character processing (CRITICAL for CTRL-C)
    // ICANON: Canonical mode (line editing)
    // ECHO: Echo input characters
    // ECHOE, ECHOK, ECHOKE: Various echo options
    // ECHOCTL: Echo control characters visibly (e.g., ^C)
    // IEXTEN: Enable extended input processing
    attrs.c_lflag |= (ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL | IEXTEN);

    // Configure input flags (c_iflag)
    // IUTF8: UTF-8 mode
    // ICRNL: Map CR to NL on input
    // IXON: Enable XON/XOFF flow control
    // BRKINT: Break generates interrupt
    attrs.c_iflag |= (IUTF8 | ICRNL | IXON | BRKINT);

    // Configure output flags (c_oflag)
    // OPOST: Enable output processing
    // ONLCR: Map NL to CR-NL on output
    attrs.c_oflag |= (OPOST | ONLCR);

    if (tcsetattr(fd, TCSANOW, &attrs) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to set terminal attributes"
            }];
        }
        return NO;
    }

    return YES;
}

+ (BOOL)resizePTY:(int)masterFD
             size:(PTYSize)size
            error:(NSError **)error {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = size.rows;
    ws.ws_col = size.cols;
    ws.ws_xpixel = size.xpixel;
    ws.ws_ypixel = size.ypixel;

    // Based on ghostty/src/pty.zig:252
    if (ioctl(masterFD, TIOCSWINSZ, &ws) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to resize PTY"
            }];
        }
        return NO;
    }

    return YES;
}

+ (nullable NSString *)slaveNameForMaster:(int)masterFD
                                    error:(NSError **)error {
    char slaveName[1024];

    if (ptsname_r(masterFD, slaveName, sizeof(slaveName)) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to get slave PTY name"
            }];
        }
        return nil;
    }

    return [NSString stringWithUTF8String:slaveName];
}

@end
