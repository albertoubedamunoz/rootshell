//
//  ProcessExecutor.h
//  rootshell-helper
//
//  Non-interactive command execution with streaming output via pipes.
//  For AI agent command execution (not interactive shell sessions).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Result of command execution
@interface ProcessExecutionResult : NSObject

/// Exit code from the process (0-255, or 128+signal if killed)
@property (nonatomic, readonly) int32_t exitCode;

/// Whether the command timed out
@property (nonatomic, readonly) BOOL timedOut;

/// Execution duration in seconds
@property (nonatomic, readonly) NSTimeInterval duration;

- (instancetype)initWithExitCode:(int32_t)exitCode
                        timedOut:(BOOL)timedOut
                        duration:(NSTimeInterval)duration;

@end

/// Callback block for streaming output
/// @param data Raw output bytes (UTF-8 encoded)
/// @param isStderr YES if from stderr, NO if from stdout
typedef void (^ProcessOutputHandler)(NSData *data, BOOL isStderr);

/// Executes commands non-interactively with pipe-based I/O
@interface ProcessExecutor : NSObject

/// Execute a command with streaming output
/// @param command Shell command to execute
/// @param cwd Working directory (nil = current directory)
/// @param environment Additional environment variables (merged with minimal shell env)
/// @param timeout Maximum execution time in seconds (0 = no timeout)
/// @param outputHandler Called with each chunk of output (may be called multiple times)
/// @param error On failure, contains error details
/// @return Result with exit code and timing, or nil on error
+ (nullable ProcessExecutionResult *)executeCommand:(NSString *)command
                                   workingDirectory:(nullable NSString *)cwd
                                        environment:(nullable NSDictionary<NSString *, NSString *> *)environment
                                            timeout:(NSTimeInterval)timeout
                                      outputHandler:(ProcessOutputHandler)outputHandler
                                              error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
