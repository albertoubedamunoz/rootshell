//
//  AVExceptionCatcher.m
//  rootshell
//

#import "AVExceptionCatcher.h"

@implementation AVExceptionCatcher

+ (NSException *)catchException:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}

@end
