#import "ObjCSupport.h"

BOOL NVTryObjC(void (NS_NOESCAPE ^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (error) {
            *error = [NSError errorWithDomain:@"NVoice.ObjCException" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: e.reason ?: e.name}];
        }
        return NO;
    }
}
