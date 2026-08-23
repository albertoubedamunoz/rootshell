//
//  PTYManagerImpl.h
//  rootshell-helper
//
//  Low-level PTY creation and management.
//  Based on ghostty/src/pty.zig and ghostty/src/Command.zig
//

#import <Foundation/Foundation.h>
#import <sys/ioctl.h>
#import <termios.h>

NS_ASSUME_NONNULL_BEGIN

/// Represents a PTY pair (master and slave file descriptors)
@interface PTYPair : NSObject

@property (nonatomic, readonly) int masterFD;
@property (nonatomic, readonly) int slaveFD;
@property (nonatomic, readonly, copy) NSString *slavePath;

- (instancetype)initWithMaster:(int)master
                         slave:(int)slave
                     slavePath:(NSString *)slavePath;

/// Closes the slave file descriptor and marks it as closed.
/// Call this in the parent process after fork() since the child has its own copy.
/// This prevents double-close issues where the fd number gets reused.
- (void)closeSlave;

/// Closes both file descriptors (only those still open)
- (void)close;

@end

/// Window size for PTY
typedef struct {
    unsigned short rows;
    unsigned short cols;
    unsigned short xpixel;  // Unused but required by struct
    unsigned short ypixel;  // Unused but required by struct
} PTYSize;

/// Low-level PTY operations
@interface PTYManagerImpl : NSObject

/// Creates a new PTY pair with the specified window size
/// Configures UTF-8 mode and sets CLOEXEC on master FD
/// Returns nil on failure
+ (nullable PTYPair *)createPTYWithSize:(PTYSize)size
                                  error:(NSError **)error;

/// Resizes an existing PTY
+ (BOOL)resizePTY:(int)masterFD
             size:(PTYSize)size
            error:(NSError **)error;

/// Gets the name of the slave PTY from a master FD
+ (nullable NSString *)slaveNameForMaster:(int)masterFD
                                    error:(NSError **)error;

/// Configures terminal attributes for UTF-8 and proper behavior
+ (BOOL)configureTerminalAttributes:(int)fd
                              error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
