#import <React/RCTBridgeModule.h>
#import <React/RCTBridge.h>

@interface VeeclipRecorder : NSObject <RCTBridgeModule>

// This property allows us to find the WebRTC module on the bridge
@property (nonatomic, weak) RCTBridge *bridge;

@end