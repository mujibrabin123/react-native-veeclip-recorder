#import "VeeclipRecorder.h"
#import <objc/runtime.h>
#import <React/RCTUIManager.h>
#import <WebRTC/RTCVideoTrack.h>
#import <WebRTC/RTCVideoFrame.h>
#import <WebRTC/RTCVideoRenderer.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCI420Buffer.h>
#import <AVFoundation/AVFoundation.h>
#import <AVFAudio/AVFAudio.h> // 🌟 NEW: Required for AVAudioEngine
#import <CoreImage/CoreImage.h>

@interface VeeclipRecorder ()
- (void)compose;
@end

@interface VeeclipFrameRenderer : NSObject <RTCVideoRenderer>
@property (nonatomic, copy) void (^onFrame)(RTCVideoFrame *frame);
@end

@implementation VeeclipFrameRenderer
- (void)setSize:(CGSize)size {}
- (void)renderFrame:(nullable RTCVideoFrame *)frame {
    if (frame && self.onFrame) self.onFrame(frame);
}
@end

@implementation VeeclipRecorder {
    VeeclipFrameRenderer *_localRenderer;
    VeeclipFrameRenderer *_remoteRenderer;
    
    RTCVideoTrack *_currentLocalTrack;
    RTCVideoTrack *_currentRemoteTrack;
    
    CVPixelBufferRef _lastLocalBuffer;
    CVPixelBufferRef _lastRemoteBuffer;
    
    RTCVideoRotation _lastLocalRotation;
    RTCVideoRotation _lastRemoteRotation;
    
    AVAssetWriter *_writer;
    AVAssetWriterInput *_videoInput;
    AVAssetWriterInputPixelBufferAdaptor *_adaptor;
    
    // 🌟 NEW: Audio Recording Variables
    AVAssetWriterInput *_audioInput;
    AVAudioEngine *_audioEngine;
    long _audioSamples;
    
    CIContext *_ciContext;
    dispatch_queue_t _processingQueue;
    dispatch_source_t _timer; 
    
    long _frameCount;
    BOOL _isRecording;
    NSString *_layout;
    
    dispatch_semaphore_t _localFrameLock;
    dispatch_semaphore_t _remoteFrameLock;
    dispatch_semaphore_t _composeLock;
}

@synthesize bridge = _bridge;

RCT_EXPORT_MODULE(VeeclipRecorder);

RCT_EXPORT_METHOD(isSupported:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {
    resolve(@YES);
}

- (CVPixelBufferRef)copyPixelBufferFrom:(RTCVideoFrame *)frame {
    if (!frame || !frame.buffer) return NULL;
    
    if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
        CVPixelBufferRef pixelBuffer = ((RTCCVPixelBuffer *)frame.buffer).pixelBuffer;
        CVPixelBufferRetain(pixelBuffer);
        return pixelBuffer;
    } else {
        id<RTCI420Buffer> i420 = [frame.buffer toI420];
        if (!i420) return NULL;
        
        CVPixelBufferRef nv12Buffer = NULL;
        NSDictionary *pixelAttributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
        CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                              i420.width,
                                              i420.height,
                                              kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                              (__bridge CFDictionaryRef)pixelAttributes,
                                              &nv12Buffer);
        
        if (result == kCVReturnSuccess && nv12Buffer) {
            CVPixelBufferLockBaseAddress(nv12Buffer, 0);
            
            uint8_t *yDest = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(nv12Buffer, 0);
            int yDestStride = (int)CVPixelBufferGetBytesPerRowOfPlane(nv12Buffer, 0);
            const uint8_t *ySrc = i420.dataY;
            for (int i = 0; i < i420.height; i++) {
                memcpy(yDest + i * yDestStride, ySrc + i * i420.strideY, i420.width);
            }
            
            uint8_t *uvDest = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(nv12Buffer, 1);
            int uvDestStride = (int)CVPixelBufferGetBytesPerRowOfPlane(nv12Buffer, 1);
            const uint8_t *uSrc = i420.dataU;
            const uint8_t *vSrc = i420.dataV;
            int uvHeight = (i420.height + 1) / 2;
            int uvWidth = (i420.width + 1) / 2;
            
            for (int i = 0; i < uvHeight; i++) {
                uint8_t *uvRow = uvDest + i * uvDestStride;
                const uint8_t *uRow = uSrc + i * i420.strideU;
                const uint8_t *vRow = vSrc + i * i420.strideV;
                for (int j = 0; j < uvWidth; j++) {
                    uvRow[j*2] = uRow[j];     
                    uvRow[j*2 + 1] = vRow[j]; 
                }
            }
            
            CVPixelBufferUnlockBaseAddress(nv12Buffer, 0);
            return nv12Buffer;
        }
    }
    return NULL;
}

- (CIImage *)fixRotationAndMirror:(CIImage *)img rotation:(RTCVideoRotation)rotation isLocal:(BOOL)isLocal {
    CGFloat radians = 0;
    switch (rotation) {
        case RTCVideoRotation_90:  radians = -M_PI_2; break; 
        case RTCVideoRotation_180: radians = -M_PI; break;   
        case RTCVideoRotation_270: radians = M_PI_2; break;  
        default: radians = 0; break;
    }
    
    if (radians != 0) {
        CGAffineTransform transform = CGAffineTransformMakeRotation(radians);
        img = [img imageByApplyingTransform:transform];
        CGAffineTransform shift = CGAffineTransformMakeTranslation(-img.extent.origin.x, -img.extent.origin.y);
        img = [img imageByApplyingTransform:shift];
    }
    
    if (isLocal) {
        CGAffineTransform flip = CGAffineTransformMakeScale(-1.0, 1.0);
        img = [img imageByApplyingTransform:flip];
        CGAffineTransform shift = CGAffineTransformMakeTranslation(img.extent.size.width, 0);
        img = [img imageByApplyingTransform:shift];
    }
    
    return img;
}

- (CIImage *)aspectFillImage:(CIImage *)img toSize:(CGSize)targetSize {
    CGFloat scaleX = targetSize.width / img.extent.size.width;
    CGFloat scaleY = targetSize.height / img.extent.size.height;
    CGFloat scale = MAX(scaleX, scaleY);
    
    CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
    CIImage *scaledImg = [img imageByApplyingTransform:transform];
    
    CGFloat tx = (targetSize.width - scaledImg.extent.size.width) / 2.0;
    CGFloat ty = (targetSize.height - scaledImg.extent.size.height) / 2.0;
    scaledImg = [scaledImg imageByApplyingTransform:CGAffineTransformMakeTranslation(tx, ty)];
    
    return [scaledImg imageByCroppingToRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
}

// 🌟 NEW: Deep CoreMedia Math to convert Raw Mic Audio into an MP4-Ready Format
// 🌟 NEW: Deep CoreMedia Math to convert Raw Mic Audio into an MP4-Ready Format
- (CMSampleBufferRef)createSampleBufferFrom:(AVAudioPCMBuffer *)buffer sampleCount:(long)sampleCount {
    
    // 🌟 FIX 1: Added 'const' to satisfy the strict C++ compiler
    const AudioBufferList *audioBufferList = buffer.audioBufferList;
    CMFormatDescriptionRef format = NULL;
    
    // 🌟 FIX 2: Provided all 8 required arguments for CMAudioFormatDescriptionCreate
    OSStatus status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, 
                                                     buffer.format.streamDescription, 
                                                     0, NULL, 0, NULL, NULL, 
                                                     &format);
    if (status != noErr) return NULL;
    
    CMBlockBufferRef blockBuffer = NULL;
    status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                NULL,
                                                audioBufferList->mBuffers[0].mDataByteSize,
                                                kCFAllocatorDefault,
                                                NULL,
                                                0,
                                                audioBufferList->mBuffers[0].mDataByteSize,
                                                kCMBlockBufferAssureMemoryNowFlag,
                                                &blockBuffer);
    
    if (status != kCMBlockBufferNoErr) {
        CFRelease(format);
        return NULL;
    }
    
    status = CMBlockBufferReplaceDataBytes(audioBufferList->mBuffers[0].mData, blockBuffer, 0, audioBufferList->mBuffers[0].mDataByteSize);
    
    // Perfectly sync the audio clock with our video clock
    CMTime pts = CMTimeMake(sampleCount, buffer.format.sampleRate);
    CMSampleTimingInfo timing = { CMTimeMake(1, buffer.format.sampleRate), pts, kCMTimeInvalid };
    
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreate(kCFAllocatorDefault,
                                  blockBuffer,
                                  true,
                                  NULL,
                                  NULL,
                                  format,
                                  buffer.frameLength,
                                  1,
                                  &timing,
                                  0,
                                  NULL,
                                  &sampleBuffer);
    
    CFRelease(blockBuffer);
    CFRelease(format);
    
    if (status != noErr) {
        if (sampleBuffer) CFRelease(sampleBuffer);
        return NULL;
    }
    
    return sampleBuffer;
}

RCT_EXPORT_METHOD(startRecording:(nonnull NSNumber *)localViewTag 
                  remoteViewTag:(nonnull NSNumber *)remoteViewTag
                  options:(NSDictionary *)options
                  resolve:(RCTPromiseResolveBlock)resolve 
                  reject:(RCTPromiseRejectBlock)reject) 
{
    if (_isRecording) {
        reject(@"ALREADY_RECORDING", @"A recording session is already active.", nil);
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *localView = [self.bridge.uiManager viewForReactTag:localViewTag];
        UIView *remoteView = [self.bridge.uiManager viewForReactTag:remoteViewTag];
        
        RTCVideoTrack *localTrack = nil;
        RTCVideoTrack *remoteTrack = nil;
        
        if ([localView respondsToSelector:NSSelectorFromString(@"videoTrack")]) {
            localTrack = [localView valueForKey:@"videoTrack"];
        }
        if ([remoteView respondsToSelector:NSSelectorFromString(@"videoTrack")]) {
            remoteTrack = [remoteView valueForKey:@"videoTrack"];
        }
        
        if (!localTrack || !remoteTrack) {
            reject(@"TRACK_ERROR", @"Native tracks not found on the provided views.", nil);
            return;
        }

        self->_layout = options[@"layout"] ? options[@"layout"] : @"vertical";
        [self setupAssetWriterWithLocalTrack:localTrack remoteTrack:remoteTrack resolve:resolve reject:reject];
    });
}

- (void)setupAssetWriterWithLocalTrack:(RTCVideoTrack *)localTrack 
                           remoteTrack:(RTCVideoTrack *)remoteTrack 
                               resolve:(RCTPromiseResolveBlock)resolve 
                                reject:(RCTPromiseRejectBlock)reject 
{
    _processingQueue = dispatch_queue_create("com.talkvee.recorder", DISPATCH_QUEUE_SERIAL);
    _ciContext = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: [NSNull null]}];
    
    _localFrameLock = dispatch_semaphore_create(1);
    _remoteFrameLock = dispatch_semaphore_create(1);
    _composeLock = dispatch_semaphore_create(1);
    
    _frameCount = 0; 
    _lastLocalBuffer = NULL;
    _lastRemoteBuffer = NULL;
    
    _localRenderer = [[VeeclipFrameRenderer alloc] init];
    _remoteRenderer = [[VeeclipFrameRenderer alloc] init];
    
    __weak VeeclipRecorder *weakSelf = self;
    
    _localRenderer.onFrame = ^(RTCVideoFrame *f) { 
        VeeclipRecorder *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_isRecording) return;

        if (dispatch_semaphore_wait(strongSelf->_localFrameLock, DISPATCH_TIME_NOW) != 0) return;

        RTCVideoRotation rot = f.rotation; 
        dispatch_async(strongSelf->_processingQueue, ^{ 
            CVPixelBufferRef copied = [strongSelf copyPixelBufferFrom:f];
            if (copied) {
                if (strongSelf->_lastLocalBuffer) CVPixelBufferRelease(strongSelf->_lastLocalBuffer);
                strongSelf->_lastLocalBuffer = copied; 
                strongSelf->_lastLocalRotation = rot; 
            }
            dispatch_semaphore_signal(strongSelf->_localFrameLock);
        });
    };
    
    _remoteRenderer.onFrame = ^(RTCVideoFrame *f) { 
        VeeclipRecorder *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_isRecording) return;

        if (dispatch_semaphore_wait(strongSelf->_remoteFrameLock, DISPATCH_TIME_NOW) != 0) return;

        RTCVideoRotation rot = f.rotation; 
        dispatch_async(strongSelf->_processingQueue, ^{ 
            CVPixelBufferRef copied = [strongSelf copyPixelBufferFrom:f];
            if (copied) {
                if (strongSelf->_lastRemoteBuffer) CVPixelBufferRelease(strongSelf->_lastRemoteBuffer);
                strongSelf->_lastRemoteBuffer = copied; 
                strongSelf->_lastRemoteRotation = rot; 
            }
            dispatch_semaphore_signal(strongSelf->_remoteFrameLock);
        });
    };

    _currentLocalTrack = localTrack;
    _currentRemoteTrack = remoteTrack;
    
    [localTrack addRenderer:self->_localRenderer];
    [remoteTrack addRenderer:self->_remoteRenderer];

    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"veeclip.mp4"];
    NSURL *url = [NSURL fileURLWithPath:path];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    
    NSError *writerError = nil;
    _writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeMPEG4 error:&writerError];
    
    if (writerError) {
        reject(@"WRITER_ERROR", @"Failed to initialize AVAssetWriter", writerError);
        return;
    }
    
    int targetWidth = [_layout isEqualToString:@"horizontal"] ? 1280 : 720;
    int targetHeight = [_layout isEqualToString:@"horizontal"] ? 720 : 1280;

    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(targetWidth),
        AVVideoHeightKey: @(targetHeight)
    };
    
    if ([_writer canApplyOutputSettings:videoSettings forMediaType:AVMediaTypeVideo]) {
        _videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
        _videoInput.expectsMediaDataInRealTime = YES;
    } else {
        reject(@"WRITER_ERROR", @"Cannot apply video output settings.", nil);
        return;
    }
    
    NSDictionary *sourcePixelBufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(targetWidth),
        (id)kCVPixelBufferHeightKey: @(targetHeight),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES 
    };
    
    _adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoInput sourcePixelBufferAttributes:sourcePixelBufferAttributes];
    
    if ([_writer canAddInput:_videoInput]) {
        [_writer addInput:_videoInput];
    } else {
        reject(@"WRITER_ERROR", @"Cannot add video input to writer.", nil);
        return;
    }
    
    // 🌟 1. Setup AVAudioEngine
    _audioEngine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *inputNode = _audioEngine.inputNode;
    AVAudioFormat *audioFormat = [inputNode inputFormatForBus:0];
    
    // 🌟 2. Dynamically configure MP4 audio settings to match the hardware rate
    NSDictionary *audioSettings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @(audioFormat.sampleRate > 0 ? audioFormat.sampleRate : 44100.0),
        AVNumberOfChannelsKey: @(audioFormat.channelCount > 0 ? audioFormat.channelCount : 1),
        AVEncoderBitRateKey: @(64000)
    };
    
    _audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
    _audioInput.expectsMediaDataInRealTime = YES;
    if ([_writer canAddInput:_audioInput]) {
        [_writer addInput:_audioInput];
    }
    
    // 🌟 3. Start the AVAssetWriter
    [_writer startWriting];
    [_writer startSessionAtSourceTime:kCMTimeZero];
    
    _isRecording = YES;
    _audioSamples = 0;
    
    // 🌟 4. Install the Audio Tap (Wiretap the mixer)
    [inputNode installTapOnBus:0 bufferSize:1024 format:audioFormat block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
        VeeclipRecorder *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_isRecording || strongSelf->_writer.status != AVAssetWriterStatusWriting) return;
        
        long currentSampleCount = strongSelf->_audioSamples;
        strongSelf->_audioSamples += buffer.frameLength;
        
        CMSampleBufferRef sampleBuffer = [strongSelf createSampleBufferFrom:buffer sampleCount:currentSampleCount];
        if (sampleBuffer) {
            if (strongSelf->_audioInput.isReadyForMoreMediaData) {
                [strongSelf->_audioInput appendSampleBuffer:sampleBuffer];
            }
            CFRelease(sampleBuffer);
        }
    }];
    
    // 🌟 5. Boot up the Audio Engine
    NSError *engineError = nil;
    [_audioEngine startAndReturnError:&engineError];
    if (engineError) {
        NSLog(@"TalkVee Audio Engine failed to start: %@", engineError.localizedDescription);
    }
    
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _processingQueue);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, (1.0 / 30.0) * NSEC_PER_SEC, (1.0 / 30.0) * NSEC_PER_SEC);
    dispatch_source_set_event_handler(_timer, ^{
        VeeclipRecorder *strongSelf = weakSelf;
        if (strongSelf) {
            if (dispatch_semaphore_wait(strongSelf->_composeLock, DISPATCH_TIME_NOW) == 0) {
                [strongSelf compose];
                dispatch_semaphore_signal(strongSelf->_composeLock);
            }
        }
    });
    dispatch_resume(_timer);
    
    resolve([NSNull null]);
}

- (void)compose {
    @autoreleasepool {
        if (!_isRecording || !_videoInput.isReadyForMoreMediaData || _writer.status != AVAssetWriterStatusWriting) return;

        if (!_lastLocalBuffer && !_lastRemoteBuffer) return;

        CVPixelBufferRef canvas = NULL;
        CVReturn status = CVPixelBufferPoolCreatePixelBuffer(NULL, _adaptor.pixelBufferPool, &canvas);
        if (status != kCVReturnSuccess || canvas == NULL) return;
        
        int w = [_layout isEqualToString:@"horizontal"] ? 1280 : 720;
        int h = [_layout isEqualToString:@"horizontal"] ? 720 : 1280;

        CIImage *bgImage = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0]] imageByCroppingToRect:CGRectMake(0, 0, w, h)];
        CIImage *finalImage = bgImage;

        if ([_layout isEqualToString:@"horizontal"]) {
            if (_lastLocalBuffer) {
                CIImage *lImg = [CIImage imageWithCVPixelBuffer:_lastLocalBuffer];
                lImg = [self fixRotationAndMirror:lImg rotation:_lastLocalRotation isLocal:YES];
                lImg = [self aspectFillImage:lImg toSize:CGSizeMake(w / 2, h)];
                finalImage = [lImg imageByCompositingOverImage:finalImage];
            }
            if (_lastRemoteBuffer) {
                CIImage *rImg = [CIImage imageWithCVPixelBuffer:_lastRemoteBuffer];
                rImg = [self fixRotationAndMirror:rImg rotation:_lastRemoteRotation isLocal:NO];
                rImg = [self aspectFillImage:rImg toSize:CGSizeMake(w / 2, h)];
                rImg = [rImg imageByApplyingTransform:CGAffineTransformMakeTranslation(w / 2, 0)];
                finalImage = [rImg imageByCompositingOverImage:finalImage];
            }
        } else {
            if (_lastRemoteBuffer) {
                CIImage *rImg = [CIImage imageWithCVPixelBuffer:_lastRemoteBuffer];
                rImg = [self fixRotationAndMirror:rImg rotation:_lastRemoteRotation isLocal:NO];
                rImg = [self aspectFillImage:rImg toSize:CGSizeMake(w, h / 2)];
                rImg = [rImg imageByApplyingTransform:CGAffineTransformMakeTranslation(0, h / 2)];
                finalImage = [rImg imageByCompositingOverImage:finalImage];
            }
            
            if (_lastLocalBuffer) {
                CIImage *lImg = [CIImage imageWithCVPixelBuffer:_lastLocalBuffer];
                lImg = [self fixRotationAndMirror:lImg rotation:_lastLocalRotation isLocal:YES];
                lImg = [self aspectFillImage:lImg toSize:CGSizeMake(w, h / 2)];
                finalImage = [lImg imageByCompositingOverImage:finalImage];
            }
        }
        
        [_ciContext render:finalImage toCVPixelBuffer:canvas];
        
        CMTime presentationTime = CMTimeMake(_frameCount, 30);
        
        if (_writer.status == AVAssetWriterStatusWriting) {
            [_adaptor appendPixelBuffer:canvas withPresentationTime:presentationTime];
            _frameCount++;
        }
        
        CVPixelBufferRelease(canvas);
    }
}

RCT_EXPORT_METHOD(stopRecording:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {
    if (!_isRecording) {
        reject(@"NOT_RECORDING", @"Recording is not currently active.", nil);
        return;
    }
    
    _isRecording = NO;
    
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    
    // 🌟 STOP AND CLEAN UP THE AUDIO ENGINE
    if (_audioEngine) {
        [_audioEngine.inputNode removeTapOnBus:0];
        [_audioEngine stop];
        _audioEngine = nil;
    }
    
    RTCVideoTrack *localTrackToClean = _currentLocalTrack;
    RTCVideoTrack *remoteTrackToClean = _currentRemoteTrack;
    VeeclipFrameRenderer *localRenToClean = _localRenderer;
    VeeclipFrameRenderer *remoteRenToClean = _remoteRenderer;
    
    _currentLocalTrack = nil;
    _currentRemoteTrack = nil;
    _localRenderer = nil;
    _remoteRenderer = nil;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (localTrackToClean && localRenToClean) [localTrackToClean removeRenderer:localRenToClean];
        if (remoteTrackToClean && remoteRenToClean) [remoteTrackToClean removeRenderer:remoteRenToClean];
    });
    
    if (_writer.status == AVAssetWriterStatusWriting) {
        [_videoInput markAsFinished];
        if (_audioInput) {
            [_audioInput markAsFinished];
        }
    }
    
    [_writer finishWritingWithCompletionHandler:^{
        dispatch_async(self->_processingQueue, ^{
            if (self->_lastLocalBuffer) { CVPixelBufferRelease(self->_lastLocalBuffer); self->_lastLocalBuffer = NULL; }
            if (self->_lastRemoteBuffer) { CVPixelBufferRelease(self->_lastRemoteBuffer); self->_lastRemoteBuffer = NULL; }
            
            self->_videoInput = nil;
            self->_audioInput = nil;
            self->_adaptor = nil;
            self->_ciContext = nil;
            
            resolve(@{@"videoUri": self->_writer.outputURL.absoluteString, @"mimeType": @"video/mp4"});
            
            self->_writer = nil;
        });
    }];
}

@end