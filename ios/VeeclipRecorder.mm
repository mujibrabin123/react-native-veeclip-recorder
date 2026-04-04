#import "VeeclipRecorder.h"

@implementation VeeclipRecorder
- (NSNumber *)multiply:(double)a b:(double)b {
    NSNumber *result = @(a * b);

    return result;
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
    return std::make_shared<facebook::react::NativeVeeclipRecorderSpecJSI>(params);
}

+ (NSString *)moduleName
{
  return @"VeeclipRecorder";
}

@end
