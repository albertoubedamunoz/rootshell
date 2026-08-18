//
//  AVExceptionCatcher.h
//  rootshell
//
//  Swift's try/catch cannot catch Objective-C NSExceptions. AVFoundation
//  APIs (notably -[AVAudioIONode setVoiceProcessingEnabled:error:]) raise
//  NSExceptions for graph configuration failures; without this bridge the
//  exception unwinds into C++ and aborts the process.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AVExceptionCatcher : NSObject

/// Runs `block` inside @try/@catch. Returns nil on success, the caught
/// NSException on failure.
+ (nullable NSException *)catchException:(NS_NOESCAPE void (^)(void))block;

@end

NS_ASSUME_NONNULL_END
