//
//  rootshell-helper-Bridging-Header.h
//  rootshell-helper
//
//  Bridging header to expose Objective-C to Swift
//

#ifndef rootshell_helper_Bridging_Header_h
#define rootshell_helper_Bridging_Header_h

// System includes for kqueue process monitoring
#include <sys/event.h>
#include <sys/un.h>

// Define LOCAL_PEERPID constants if not available
// These are used to get the peer PID from a Unix domain socket
#ifndef SOL_LOCAL
#define SOL_LOCAL 0
#endif

#ifndef LOCAL_PEERPID
#define LOCAL_PEERPID 2
#endif

// PTY Management
#import "PTYManagerImpl.h"

// Process Spawning
#import "ProcessSpawner.h"

// Non-interactive Command Execution
#import "ProcessExecutor.h"

// FD Passing Server
#import "FDPassingServer.h"

#endif /* rootshell_helper_Bridging_Header_h */
