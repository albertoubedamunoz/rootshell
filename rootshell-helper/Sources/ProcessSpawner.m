//
//  ProcessSpawner.m
//  rootshell-helper
//
//  Process spawning implementation using fork/exec
//  Based on ghostty/src/termio/Exec.zig
//

#import "ProcessSpawner.h"
#import <sys/wait.h>
#import <sys/stat.h>
#import <sys/ioctl.h>
#import <pwd.h>
#import <signal.h>
#import <unistd.h>

@implementation ShellSpawnConfig

- (instancetype)init {
    if (self = [super init]) {
        _size = (PTYSize){24, 80, 0, 0};
        _environment = @{};
        _enableShellIntegration = NO;
    }
    return self;
}

@end

@implementation ShellSpawnResult

- (instancetype)initWithPID:(pid_t)pid pty:(PTYPair *)pty {
    if (self = [super init]) {
        _pid = pid;
        _pty = pty;
    }
    return self;
}

@end

@implementation ProcessSpawner

+ (nullable ShellSpawnResult *)spawnShellWithConfig:(ShellSpawnConfig *)config
                                              error:(NSError **)error {
    NSError *localError = nil;

    // Create PTY pair
    PTYPair *pty = [PTYManagerImpl createPTYWithSize:config.size error:&localError];
    if (!pty) {
        if (error) *error = localError;
        return nil;
    }

    // Get user information
    NSString *username = [self currentUsername:&localError];
    if (!username) {
        if (error) *error = localError;
        [pty close];
        return nil;
    }

    // Get shell
    NSString *shell = config.shell;
    if (!shell) {
        shell = [self defaultShellForUser:&localError];
        if (!shell) {
            if (error) *error = localError;
            [pty close];
            return nil;
        }
    }

    // Build command arguments
    NSArray<NSString *> *args;
    if (config.command) {
        // Custom command
        args = config.command;
    } else {
        // Use /usr/bin/login to get proper login shell behavior
        // This matches macOS Ghostty and ensures proper session/foreground setup
        args = [self buildLoginCommandWithUsername:username shell:shell];
        NSLog(@"Launching via /usr/bin/login: %@", shell);
    }

    // Convert to C strings
    char **argv = [self convertToCStringArray:args];
    if (!argv) {
        if (error) {
            *error = [NSError errorWithDomain:@"ProcessSpawner"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to convert arguments"}];
        }
        [pty close];
        return nil;
    }

    // Build environment
    char **envp = [self buildEnvironment:config.environment];
    if (!envp) {
        [self freeCStringArray:argv];
        if (error) {
            *error = [NSError errorWithDomain:@"ProcessSpawner"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to build environment"}];
        }
        [pty close];
        return nil;
    }

    // Fork the process
    // Based on ghostty/src/termio/Exec.zig
    pid_t pid = fork();

    if (pid < 0) {
        // Fork failed
        int fork_errno = errno;
        [self freeCStringArray:argv];
        [self freeCStringArray:envp];
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:fork_errno
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to fork process",
                NSLocalizedFailureReasonErrorKey: [NSString stringWithUTF8String:strerror(fork_errno)]
            }];
        }
        [pty close];
        return nil;
    }

    if (pid == 0) {
        // Child process
        // Based on ghostty/src/pty.zig:125-176 (childPreExec)

        // Redirect stdin, stdout, stderr to slave PTY FIRST
        // This way all error messages will go to the PTY
        dup2(pty.slaveFD, STDIN_FILENO);
        dup2(pty.slaveFD, STDOUT_FILENO);
        dup2(pty.slaveFD, STDERR_FILENO);

        // Create new session and become session leader
        if (setsid() < 0) {
            perror("setsid failed");
            _exit(1);
        }

        // Set the slave PTY as the controlling terminal
        if (ioctl(pty.slaveFD, TIOCSCTTY, 0) < 0) {
            perror("TIOCSCTTY failed");
            _exit(1);
        }

        // Note: We don't call tcsetpgrp() here - let bash/login handle it during initialization

        // CRITICAL: Unblock all signals first
        // The child inherits the parent's signal mask, and if SIGINT is blocked,
        // it will never be delivered even if ISIG is enabled on the PTY
        sigset_t unblock_all;
        sigemptyset(&unblock_all);
        sigprocmask(SIG_SETMASK, &unblock_all, NULL);

        // Reset signal handlers to defaults
        // (fork inherits signal handlers from parent)
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = SIG_DFL;
        sigemptyset(&sa.sa_mask);

        for (int sig = 1; sig < NSIG; sig++) {
            // Skip signals that can't be caught
            if (sig == SIGKILL || sig == SIGSTOP) continue;
            sigaction(sig, &sa, NULL);
        }

        // Close all other file descriptors
        // Close master and slave (we've dup'd slave to 0/1/2)
        close(pty.masterFD);
        if (pty.slaveFD > STDERR_FILENO) {
            close(pty.slaveFD);
        }

        // Change working directory
        // If not specified, default to user's home directory
        NSString *targetDir = config.workingDirectory;
        if (!targetDir) {
            targetDir = NSHomeDirectory();
        }

        if (targetDir && chdir([targetDir UTF8String]) != 0) {
            perror("chdir failed");
            _exit(1);
        }

        // Execute the command
        // /usr/bin/login (for shells) or custom command
        execve(argv[0], argv, envp);

        // If we get here, exec failed
        perror("execve failed");
        fprintf(stderr, "Failed to exec: %s\n", argv[0]);
        _exit(127);
    }

    // Parent process

    // Close slave FD in parent (child has its own copy)
    // IMPORTANT: Use closeSlave() method to mark it as closed in PTYPair.
    // Otherwise PTYPair.close() will try to close this fd again later,
    // but by then the fd number may have been reused for something else
    // (like the kqueue for client monitoring), causing subtle bugs.
    [pty closeSlave];

    // Note: The child process sets itself as foreground via tcsetpgrp() before exec
    // We don't do it from the parent because tcsetpgrp() must be called from within the session

    // IMPORTANT: Don't free argv/envp yet! The child process needs them for execve().
    // After fork(), the child shares memory pages with parent (copy-on-write).
    // If we free these arrays now, the child's pointers become invalid.
    // We need to delay freeing until after child has called execve().
    // Small memory leak, but necessary for correctness.
    // TODO: Use vfork() instead of fork() to avoid this issue, or
    // add synchronization to free after child execs.

    // [self freeCStringArray:argv];  // Commented out - causes child to get garbage
    // [self freeCStringArray:envp];  // Commented out - causes child to get garbage

    return [[ShellSpawnResult alloc] initWithPID:pid pty:pty];
}

+ (NSArray<NSString *> *)buildLoginCommandWithUsername:(NSString *)username
                                                  shell:(NSString *)shell {
    // Based on ghostty/src/termio/Exec.zig:1518-1549
    // Command: /usr/bin/login -q -flp USERNAME /bin/bash --noprofile --norc -c "exec -l SHELL"

    NSMutableArray *args = [NSMutableArray array];

    [args addObject:@"/usr/bin/login"];

    // Add -q flag if user has hushlogin
    if ([self hasHushlogin]) {
        [args addObject:@"-q"];
    }

    // -f: Skip authentication
    // -l: Don't change to home directory (preserves CWD)
    // -p: Preserve environment
    [args addObject:@"-flp"];
    [args addObject:username];

    // Use bash to exec the actual shell
    // Bash is faster than zsh for this operation (~2x)
    [args addObject:@"/bin/bash"];
    [args addObject:@"--noprofile"];
    [args addObject:@"--norc"];
    [args addObject:@"-c"];

    // exec -l replaces bash with the user's shell as a login shell
    NSString *execCmd = [NSString stringWithFormat:@"exec -l %@", shell];
    [args addObject:execCmd];

    return args;
}

+ (BOOL)hasHushlogin {
    // Check for ~/.hushlogin
    // Based on ghostty/src/termio/Exec.zig:1473-1517
    NSString *homedir = NSHomeDirectory();
    NSString *hushloginPath = [homedir stringByAppendingPathComponent:@".hushlogin"];

    struct stat st;
    return (stat([hushloginPath UTF8String], &st) == 0);
}

+ (nullable NSString *)defaultShellForUser:(NSError **)error {
    struct passwd *pw = getpwuid(getuid());
    if (!pw || !pw->pw_shell) {
        if (error) {
            *error = [NSError errorWithDomain:@"ProcessSpawner"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to get user shell"}];
        }
        return nil;
    }

    return [NSString stringWithUTF8String:pw->pw_shell];
}

+ (nullable NSString *)currentUsername:(NSError **)error {
    struct passwd *pw = getpwuid(getuid());
    if (!pw || !pw->pw_name) {
        if (error) {
            *error = [NSError errorWithDomain:@"ProcessSpawner"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to get username"}];
        }
        return nil;
    }

    return [NSString stringWithUTF8String:pw->pw_name];
}

+ (int)waitForProcess:(pid_t)pid blocking:(BOOL)blocking {
    int status;
    int options = blocking ? 0 : WNOHANG;

    pid_t result = waitpid(pid, &status, options);

    if (result == 0) {
        // Process still running (non-blocking)
        return -1;
    } else if (result < 0) {
        // Error
        return -1;
    }

    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }

    return -1;
}

+ (BOOL)killProcess:(pid_t)pid signal:(int)signal error:(NSError **)error {
    if (kill(pid, signal) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to send signal %d to process", signal]
            }];
        }
        return NO;
    }
    return YES;
}

#pragma mark - Helper Methods

+ (char **)convertToCStringArray:(NSArray<NSString *> *)strings {
    if (!strings) return NULL;

    size_t count = strings.count;
    char **array = malloc((count + 1) * sizeof(char *));
    if (!array) return NULL;

    for (size_t i = 0; i < count; i++) {
        const char *str = [strings[i] UTF8String];
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

+ (char **)buildEnvironment:(NSDictionary<NSString *, NSString *> *)customEnv {
    // DON'T inherit current environment - use ONLY what EnvironmentBuilder provides
    // This prevents iOS/Xcode-specific variables from leaking into shells and
    // breaking downstream tools like openssl, python, etc.
    // The login shell will set up the rest via /etc/profile, ~/.zshrc, etc.
    NSMutableDictionary *env = [NSMutableDictionary dictionaryWithDictionary:customEnv];

    // Convert to C array
    NSMutableArray *envStrings = [NSMutableArray array];
    for (NSString *key in env) {
        NSString *entry = [NSString stringWithFormat:@"%@=%@", key, env[key]];
        [envStrings addObject:entry];
    }

    return [self convertToCStringArray:envStrings];
}

+ (void)freeCStringArray:(char **)array {
    if (!array) return;

    for (char **ptr = array; *ptr != NULL; ptr++) {
        free(*ptr);
    }
    free(array);
}

@end
