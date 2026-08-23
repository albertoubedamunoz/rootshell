//
//  ProcessExecutor.m
//  rootshell-helper
//
//  Non-interactive command execution via fork/exec with pipes.
//  Streams output in real-time via callback block.
//

#import "ProcessExecutor.h"
#import <sys/wait.h>
#import <sys/select.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <pwd.h>

// Read buffer size for pipe I/O
#define PIPE_BUFFER_SIZE 4096

// Grace period before SIGKILL after SIGTERM (seconds)
#define KILL_GRACE_PERIOD 1.0

@implementation ProcessExecutionResult

- (instancetype)initWithExitCode:(int32_t)exitCode
                        timedOut:(BOOL)timedOut
                        duration:(NSTimeInterval)duration {
    if (self = [super init]) {
        _exitCode = exitCode;
        _timedOut = timedOut;
        _duration = duration;
    }
    return self;
}

@end

@implementation ProcessExecutor

+ (nullable ProcessExecutionResult *)executeCommand:(NSString *)command
                                   workingDirectory:(nullable NSString *)cwd
                                        environment:(nullable NSDictionary<NSString *, NSString *> *)environment
                                            timeout:(NSTimeInterval)timeout
                                      outputHandler:(ProcessOutputHandler)outputHandler
                                              error:(NSError **)error {
    NSDate *startTime = [NSDate date];

    // Create pipes for stdout and stderr
    int stdoutPipe[2];  // [0] = read end, [1] = write end
    int stderrPipe[2];

    if (pipe(stdoutPipe) < 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to create stdout pipe"}];
        }
        return nil;
    }

    if (pipe(stderrPipe) < 0) {
        close(stdoutPipe[0]);
        close(stdoutPipe[1]);
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to create stderr pipe"}];
        }
        return nil;
    }

    // Set close-on-exec for read ends (parent will use these)
    fcntl(stdoutPipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(stderrPipe[0], F_SETFD, FD_CLOEXEC);

    // Get user's default shell for command execution
    NSString *shell = [self defaultShell];

    // Build command string: $SHELL -l -c 'command'
    // Using login shell (-l) to get user's environment (PATH, etc.)
    const char *shellPath = [shell UTF8String];
    const char *cmdStr = [command UTF8String];

    // Build argv: [shell, "-l", "-c", command, NULL]
    char *argv[] = {
        (char *)shellPath,
        "-l",
        "-c",
        (char *)cmdStr,
        NULL
    };

    // Build environment
    char **envp = [self buildEnvironmentWithCustom:environment];
    if (!envp) {
        close(stdoutPipe[0]);
        close(stdoutPipe[1]);
        close(stderrPipe[0]);
        close(stderrPipe[1]);
        if (error) {
            *error = [NSError errorWithDomain:@"ProcessExecutor"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to build environment"}];
        }
        return nil;
    }

    // Fork the process
    pid_t pid = fork();

    if (pid < 0) {
        // Fork failed
        int forkErrno = errno;
        close(stdoutPipe[0]);
        close(stdoutPipe[1]);
        close(stderrPipe[0]);
        close(stderrPipe[1]);
        [self freeEnvironment:envp];
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:forkErrno
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to fork process"}];
        }
        return nil;
    }

    if (pid == 0) {
        // Child process

        // Close read ends (parent uses these)
        close(stdoutPipe[0]);
        close(stderrPipe[0]);

        // stdin: never inherit the helper's (it is the app's — and under a
        // debugger, Xcode's console pty; a login-shell child poking at that
        // terminal can wedge the whole console session).
        int devNull = open("/dev/null", O_RDONLY);
        if (devNull >= 0) {
            dup2(devNull, STDIN_FILENO);
            if (devNull != STDIN_FILENO) close(devNull);
        }

        // Redirect stdout and stderr to pipes
        dup2(stdoutPipe[1], STDOUT_FILENO);
        dup2(stderrPipe[1], STDERR_FILENO);

        // Close original write ends (now duplicated)
        close(stdoutPipe[1]);
        close(stderrPipe[1]);

        // Drop every other inherited descriptor: the helper holds shell PTY
        // masters, app sockets, and (under Xcode) console plumbing that a
        // spawned command tree must never touch or keep alive.
        int maxFD = (int)sysconf(_SC_OPEN_MAX);
        if (maxFD <= 0 || maxFD > 10240) maxFD = 10240;
        for (int fd = 3; fd < maxFD; fd++) {
            close(fd);
        }

        // Create new session (detach from controlling terminal)
        setsid();

        // Unblock all signals
        sigset_t unblockAll;
        sigemptyset(&unblockAll);
        sigprocmask(SIG_SETMASK, &unblockAll, NULL);

        // Reset signal handlers to defaults
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = SIG_DFL;
        sigemptyset(&sa.sa_mask);

        for (int sig = 1; sig < NSIG; sig++) {
            if (sig == SIGKILL || sig == SIGSTOP) continue;
            sigaction(sig, &sa, NULL);
        }

        // Change working directory
        if (cwd) {
            if (chdir([cwd UTF8String]) != 0) {
                perror("chdir failed");
                _exit(1);
            }
        }

        // Execute the command
        execve(shellPath, argv, envp);

        // If we get here, exec failed
        perror("execve failed");
        _exit(127);
    }

    // Parent process

    // Close write ends (child uses these)
    close(stdoutPipe[1]);
    close(stderrPipe[1]);

    // Note: Don't free envp yet - child may still need it before execve
    // (copy-on-write memory sharing after fork)
    // Small leak, but necessary for correctness

    // Set non-blocking mode on read ends
    fcntl(stdoutPipe[0], F_SETFL, O_NONBLOCK);
    fcntl(stderrPipe[0], F_SETFL, O_NONBLOCK);

    // Read from pipes until child exits or timeout
    BOOL timedOut = NO;
    int exitCode = 0;
    uint8_t buffer[PIPE_BUFFER_SIZE];

    while (YES) {
        // Check if child has exited
        int status;
        pid_t waitResult = waitpid(pid, &status, WNOHANG);

        if (waitResult > 0) {
            // Child has exited - read any remaining data then break
            [self drainPipe:stdoutPipe[0] isStderr:NO handler:outputHandler];
            [self drainPipe:stderrPipe[0] isStderr:YES handler:outputHandler];

            if (WIFEXITED(status)) {
                exitCode = WEXITSTATUS(status);
            } else if (WIFSIGNALED(status)) {
                exitCode = 128 + WTERMSIG(status);
            }
            break;
        }

        // Check timeout
        if (timeout > 0) {
            NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:startTime];
            if (elapsed >= timeout) {
                timedOut = YES;

                // Kill the process
                kill(pid, SIGTERM);

                // Wait briefly then SIGKILL if still running
                usleep((useconds_t)(KILL_GRACE_PERIOD * 1000000));
                if (waitpid(pid, NULL, WNOHANG) == 0) {
                    kill(pid, SIGKILL);
                }

                // Reap the zombie
                waitpid(pid, &status, 0);

                if (WIFEXITED(status)) {
                    exitCode = WEXITSTATUS(status);
                } else if (WIFSIGNALED(status)) {
                    exitCode = 128 + WTERMSIG(status);
                }
                break;
            }
        }

        // Use select() to wait for data with timeout
        fd_set readFds;
        FD_ZERO(&readFds);
        FD_SET(stdoutPipe[0], &readFds);
        FD_SET(stderrPipe[0], &readFds);

        int maxFd = (stdoutPipe[0] > stderrPipe[0]) ? stdoutPipe[0] : stderrPipe[0];

        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 100000;  // 100ms poll interval

        int selectResult = select(maxFd + 1, &readFds, NULL, NULL, &tv);

        if (selectResult > 0) {
            // Read from stdout
            if (FD_ISSET(stdoutPipe[0], &readFds)) {
                ssize_t bytesRead;
                while ((bytesRead = read(stdoutPipe[0], buffer, sizeof(buffer))) > 0) {
                    NSData *data = [NSData dataWithBytes:buffer length:bytesRead];
                    outputHandler(data, NO);
                }
            }

            // Read from stderr
            if (FD_ISSET(stderrPipe[0], &readFds)) {
                ssize_t bytesRead;
                while ((bytesRead = read(stderrPipe[0], buffer, sizeof(buffer))) > 0) {
                    NSData *data = [NSData dataWithBytes:buffer length:bytesRead];
                    outputHandler(data, YES);
                }
            }
        }
    }

    // Close pipe read ends
    close(stdoutPipe[0]);
    close(stderrPipe[0]);

    NSTimeInterval duration = [[NSDate date] timeIntervalSinceDate:startTime];

    return [[ProcessExecutionResult alloc] initWithExitCode:exitCode
                                                   timedOut:timedOut
                                                   duration:duration];
}

#pragma mark - Helper Methods

/// Drain any remaining data from a pipe
+ (void)drainPipe:(int)fd isStderr:(BOOL)isStderr handler:(ProcessOutputHandler)handler {
    uint8_t buffer[PIPE_BUFFER_SIZE];
    ssize_t bytesRead;

    while ((bytesRead = read(fd, buffer, sizeof(buffer))) > 0) {
        NSData *data = [NSData dataWithBytes:buffer length:bytesRead];
        handler(data, isStderr);
    }
}

/// Get user's default shell
+ (NSString *)defaultShell {
    struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_shell) {
        return [NSString stringWithUTF8String:pw->pw_shell];
    }
    return @"/bin/sh";
}

/// Build environment array with minimal required variables plus custom ones
+ (char **)buildEnvironmentWithCustom:(nullable NSDictionary<NSString *, NSString *> *)customEnv {
    NSMutableDictionary *env = [NSMutableDictionary dictionary];

    // Add minimal required environment
    // The login shell will set up the rest via /etc/profile, ~/.zshrc, etc.
    env[@"PATH"] = @"/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    env[@"TERM"] = @"xterm-256color";
    env[@"HOME"] = NSHomeDirectory();

    // Get user info
    struct passwd *pw = getpwuid(getuid());
    if (pw) {
        if (pw->pw_name) {
            env[@"USER"] = [NSString stringWithUTF8String:pw->pw_name];
            env[@"LOGNAME"] = env[@"USER"];
        }
        if (pw->pw_shell) {
            env[@"SHELL"] = [NSString stringWithUTF8String:pw->pw_shell];
        }
    }

    // Merge custom environment (overrides defaults)
    if (customEnv) {
        [env addEntriesFromDictionary:customEnv];
    }

    // Convert to C array
    NSMutableArray *envStrings = [NSMutableArray arrayWithCapacity:env.count];
    for (NSString *key in env) {
        NSString *entry = [NSString stringWithFormat:@"%@=%@", key, env[key]];
        [envStrings addObject:entry];
    }

    size_t count = envStrings.count;
    char **array = malloc((count + 1) * sizeof(char *));
    if (!array) return NULL;

    for (size_t i = 0; i < count; i++) {
        const char *str = [envStrings[i] UTF8String];
        array[i] = strdup(str);
        if (!array[i]) {
            // Cleanup on failure
            for (size_t j = 0; j < i; j++) {
                free(array[j]);
            }
            free(array);
            return NULL;
        }
    }

    array[count] = NULL;
    return array;
}

/// Free environment array
+ (void)freeEnvironment:(char **)envp {
    if (!envp) return;

    for (char **ptr = envp; *ptr != NULL; ptr++) {
        free(*ptr);
    }
    free(envp);
}

@end
