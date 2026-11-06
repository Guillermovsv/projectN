#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Runs `block` and converts an Objective-C exception (e.g. AVAudioEngine's format-mismatch
/// exceptions after the audio device changes) into an NSError instead of crashing the app.
BOOL NVTryObjC(void (NS_NOESCAPE ^block)(void), NSError * _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
