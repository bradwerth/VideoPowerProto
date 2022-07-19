//
//  VideoHolder.m
//  video-low-power
//
//  Created by Brad Werth on 6/10/21.
//

#import <AVKit/AVKit.h>
#import <CoreMedia/CoreMedia.h>

#import "VideoHolder.h"
#import "MainViewController.h"
#import "VideoModel.h"

@implementation VideoHolder {
  // videoLayer is a retained reference to the layer that actually displays
  // the video content.
  CALayer* videoLayer;
  // avLayer is an unretained alias of videoLayer that indicates we're using
  // this type of layer.
  AVSampleBufferDisplayLayer* avLayer;
  // overlayLayer appears on top of videoLayer and has some obscuring content.
  // It is revealed or hidden to see its effect on detached mode.
  CALayer* overlayLayer;
  // overlayTimer controls the flashing over the overlayLayer.
  NSTimer* overlayTimer;
  // frameSurface is the image content displayed by the videoLayer, if we are
  // being fed frames directly.
  IOSurfaceRef frameSurface;

  VideoModel* lastModel;
  float aspectRatio;
  CGFloat trackWidth;
  dispatch_queue_global_t queueToUse;

  CMTime presentationTimeOfLastBuffer;
}

const int32_t kStoredBufferMax = 10;

- (void)awakeFromNib {
  // Treat this as our initialization method, and set properties we'll need to
  // act as a layer-backed view.
  videoLayer = nil;
  overlayLayer = nil;
  avLayer = nil;
  frameSurface = nil;
  lastModel = nil;
  aspectRatio = 1.0f;
  trackWidth = 0.0f;
  queueToUse = dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0);
  presentationTimeOfLastBuffer = kCMTimeInvalid;

  // Set some initial properties on our backing layer.
  self.wantsLayer = YES;
  if (!self.layer) {
    [self makeBackingLayer];
  }
  assert(self.layer);

  self.layer.position = NSZeroPoint;
  self.layer.anchorPoint = NSZeroPoint;
  self.layer.contentsGravity = kCAGravityTopLeft;
  self.layer.contentsScale = 1;
  self.layer.bounds = NSZeroRect;
  self.layer.edgeAntialiasingMask = 0;
  self.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
  self.layer.opaque = YES;

  // Listen to changes in our frame bounds so we can re-center our layer.
  self.postsBoundsChangedNotifications = YES;
  VideoHolder* holder = self;
  [[NSNotificationCenter defaultCenter] addObserverForName:NSViewFrameDidChangeNotification object:self queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification* note) {
    [holder centerLayers];
  }];
}

- (void)dealloc {
  if (frameSurface) {
    CFRelease(frameSurface);
  }
  frameSurface = nil;

  if (overlayTimer) {
    [overlayTimer invalidate];
  }
  [overlayTimer release];
  overlayTimer = nil;

  [super dealloc];
}

- (void)resetWithModel:(VideoModel* _Nullable)model {
  // Copy the model to lock in its values, then release the old model.
  VideoModel *oldModel = lastModel;
  lastModel = [model copy];
  [oldModel release];

  [self recreatevideoLayer];
}

- (void)resetOverlayTimer {
  if (overlayTimer) {
    [overlayTimer invalidate];
  }
  [overlayTimer release];

  // Create the overlayTimer.
  void (^overlayBlock)(NSTimer *) = ^(NSTimer* timer) {
      if (lastModel.flashingOverlay && overlayLayer)  {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        overlayLayer.hidden = !overlayLayer.hidden;
        [CATransaction commit];
      }
    };
  overlayTimer = [[NSTimer scheduledTimerWithTimeInterval:3.0
                           repeats:YES
                           block:overlayBlock] retain];
}

- (void)recreatevideoLayer {
  // Stop any requests from our last model.
  if (avLayer) {
    [avLayer stopRequestingMediaData];
  }

  presentationTimeOfLastBuffer = kCMTimeInvalid;

  // Remove all the sublayers of the backing layer.
  [videoLayer release];
  videoLayer = nil;
  avLayer = nil;
  [overlayLayer release];
  overlayLayer = nil;
  self.layer.sublayers = nil;

  if (!lastModel) {
    return;
  }

  if (lastModel.layerClass == LayerClassCALayer) {
    //NSLog(@"recreatevideoLayer CALayer.");
    videoLayer = [[CALayer layer] retain];
    videoLayer.delegate = (id)self;
    videoLayer.needsDisplayOnBoundsChange = YES;
  } else if (lastModel.layerClass == LayerClassAVSampleBufferDisplayLayer) {
    //NSLog(@"recreatevideoLayer AVSampleBufferDisplayLayer.");
    avLayer = [[AVSampleBufferDisplayLayer layer] retain];
    CMTimebaseRef timebase;
    CMTimebaseCreateWithMasterClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &timebase);
    CMTimebaseSetRate(timebase, 1.0f);
    avLayer.controlTimebase = timebase;
    CFRelease(timebase);
    videoLayer = avLayer;
  }

  videoLayer.position = NSZeroPoint;
  videoLayer.anchorPoint = NSZeroPoint;
  videoLayer.contentsGravity = kCAGravityTopLeft;
  videoLayer.contentsScale = 1;
  videoLayer.bounds = NSMakeRect(0.0f, 0.0f, 16.0f, 9.0f);
  videoLayer.opaque = YES;

  [self.layer addSublayer:videoLayer];

  if (lastModel.flashingOverlay) {
    overlayLayer = [[CALayer layer] retain];
    overlayLayer.backgroundColor = CGColorGetConstantColor(kCGColorWhite);
    overlayLayer.position = NSZeroPoint;
    overlayLayer.anchorPoint = NSZeroPoint;
    overlayLayer.bounds = NSMakeRect(0.0f, 0.0f, 100.0f, 100.0f);
    overlayLayer.opaque = YES;

    [self.layer addSublayer:overlayLayer];

    [self resetOverlayTimer];
  }

  VideoHolder* holder = self;
  // Figure out the size of the video in the model, then center the content
  // and start requesting frames.
  [lastModel waitForVideoAssetFirstTrack:^(AVAssetTrack* track) {
    if (!track) {
      return;
    }

    CGSize trackSize = track.naturalSize;
    trackWidth = trackSize.width;
    if (trackWidth >= 0.0 && trackSize.height >= 0.0) {
      aspectRatio = trackWidth / trackSize.height;
    } else {
      aspectRatio = 16.0f / 9.0f;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      [holder centerLayers];
    });

    // Start requesting frames.
    if (avLayer && lastModel.willRequestFramesRepeatedly) {
      [avLayer requestMediaDataWhenReadyOnQueue:queueToUse usingBlock:^{
        [holder enqueueMoreFrames];
      }];
    } else {
      [holder enqueueMoreFrames];
    }
  }];
}

- (CALayer*)detachVideoLayer {
  if (videoLayer) {
    [videoLayer removeFromSuperlayer];
  }
  return videoLayer;
}

- (void)reattachVideoLayer {
  [self.layer addSublayer:videoLayer];
  [self centerLayers];
}

- (CALayer*)detachOverlayLayer {
  if (overlayLayer) {
    [overlayLayer removeFromSuperlayer];
  }
  return overlayLayer;
}

- (void)reattachOverlayLayer {
  [self.layer addSublayer:overlayLayer];
  [self centerLayers];
}

- (void)enqueueMoreFrames {
  [self.controller requestFrames];
}

- (void)centerLayers {
  if (!videoLayer) {
    return;
  }
  CGSize viewSize = self.bounds.size;

  // First, see if we are height-limited.
  CGFloat requestedWidth = viewSize.height * aspectRatio;
  CGFloat requestedHeight = viewSize.height;
  if (requestedWidth > viewSize.width) {
    requestedWidth = viewSize.width;
    requestedHeight = viewSize.width / aspectRatio;
  }

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  videoLayer.position = CGPointMake((viewSize.width - requestedWidth) * 0.5f, (viewSize.height - requestedHeight) * 0.5f);
  videoLayer.bounds = CGRectMake(0.0f, 0.0f, requestedWidth, requestedHeight);

  // Figure out the correct scale to display this frame. Since the layer is
  // scaled to the aspect ratio of the content, we can just compute this based
  // on the width of the frame divided by the width of the layer.
  CGFloat scale = trackWidth / requestedWidth;
  videoLayer.contentsScale = scale;

  [CATransaction commit];
}

- (BOOL)wantsMoreFrames {
  if (avLayer) {
    return [avLayer isReadyForMoreMediaData];
  }
  return YES;
}

- (BOOL)handleBuffer:(CMSampleBufferRef)buffer {
  if (!lastModel || !lastModel.canHandleBuffers) {
    return NO;
  }

  //NSLog(@"handleBuffer buffer is %@.", buffer);

  presentationTimeOfLastBuffer = CMSampleBufferGetOutputPresentationTimeStamp(buffer);

  // Track whether we want more buffers. Generally, we do, but certain buffer
  // properties and the state of our display layer may change that.
  BOOL weWantMoreBuffers = YES;

  // Check for interesting buffer attachments.
  CFTypeRef attachment;

  // Should we post that we've consumed this buffer?
  if ((attachment = CMGetAttachment(buffer, kCMSampleBufferAttachmentKey_PostNotificationWhenConsumed, NULL))) {
    //NSLog(@"handleBuffer post notification buffer.");
    CFNotificationCenterRef center = CFNotificationCenterGetLocalCenter();
    CFNotificationCenterPostNotification(center, kCMSampleBufferConsumerNotification_BufferConsumed , self, attachment, false);
  }

  // Display/decode anything that's displayable.
  CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(buffer);
  BOOL canDisplay = !!format;
  if (canDisplay) {
    // It's possible that our layer can't handle any more frames.
    if ([avLayer status] == AVQueuedSampleBufferRenderingStatusFailed) {
      [self recreatevideoLayer];
      assert(avLayer);
    }

    /*
    if ([avLayer requiresFlushToResumeDecoding]) {
      [avLayer flush];
    }
    */

    [avLayer enqueueSampleBuffer:buffer];

    // Don't ask for more buffers if the layer can't handle them.
    weWantMoreBuffers &= [avLayer isReadyForMoreMediaData];
  }

  return weWantMoreBuffers;
}

- (void)restartAtTime:(CMTime)targetTime {
  if (avLayer) {
    // Define a block that we'll use to reset the video.
    void (^loopBlock)(CFRunLoopTimerRef) = ^(CFRunLoopTimerRef timer) {
      CMTimebaseSetTime(avLayer.controlTimebase, CMTimeMake(0, 1));
      if (lastModel.willRequestFramesRepeatedly) {
        VideoHolder* holder = self;
        [avLayer requestMediaDataWhenReadyOnQueue:queueToUse usingBlock:^{
          [holder enqueueMoreFrames];
        }];
      }
    };

    // Setup a timer to trigger at time.
    CMTime nowTime = CMTimebaseGetTime(avLayer.controlTimebase);
    CMTime timeDiff = CMTimeSubtract(targetTime, nowTime);
    Float64 seconds = CMTimeGetSeconds(timeDiff);
    if (seconds <= 0.0) {
      // Just call the block right now.
      loopBlock(nil);
      return;
    }

    // Schedule the block to be called in seconds from now.
    CFAbsoluteTime absoluteNow = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime absoluteTarget = absoluteNow + seconds;

    CFRunLoopRef runLoop = CFRunLoopGetMain();
    CFRunLoopTimerRef loopTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, absoluteTarget, 0, 0, 0, loopBlock);
    CFRunLoopAddTimer(runLoop, loopTimer, kCFRunLoopDefaultMode);
    CFRelease(loopTimer);

    // TODO: In theory, we should be able to associate the timer with avLayer
    // controlTimebase by calling CMTimebaseSetTimerNextFireTime. This is
    // useful in case the time or rate of the timebase is ever changed, it
    // would ensure that the timer fires at the expected time. However, that
    // call doesn't have any noticeable effect, so we use the absolute time and
    // an absolute timer instead.
    /*
    // Associate the timer with the timebase, then reset the time relative to
    // the timebase.
    CMTimebaseAddTimer(avLayer.controlTimebase, loopTimer, runLoop);
    CMTimebaseSetTimerNextFireTime(avLayer.controlTimebase, loopTimer, targetTime, 0);
    */
  }
}

- (BOOL)handleFrame:(IOSurfaceRef)surface {
  if (avLayer) {
    return [self handleFrameAsBuffer:surface];
  }

  // We might have a stale frameSurface. If we do, capture it and release it
  // after we have updated frameSurface.
  IOSurfaceRef staleFrameSurface = frameSurface;

  // Store the surface for later display.
  frameSurface = surface;
  CFRetain(frameSurface);

  if (staleFrameSurface) {
    CFRelease(staleFrameSurface);
  }

  CALayer* currentvideoLayer = [videoLayer retain];
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([currentvideoLayer superlayer]) {
      [currentvideoLayer setNeedsDisplay];
    }
    [currentvideoLayer release];
  });
  return YES;
}

- (BOOL)handleFrameAsBuffer:(IOSurfaceRef)surface {
  //NSLog(@"handleFrameAsBuffer.");

  // Convert the IOSurface into a CMSampleBuffer, so we can enqueue it in
  // avLayer.
  CVPixelBufferRef pixelBuffer = nil;
  CVReturn cvValue =
      CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nil, &pixelBuffer);
  if (cvValue != kCVReturnSuccess) {
    NSLog(@"Couldn't extract pixel buffer from frame surface.");
    return NO;
  }

  /*
  // Transform the pixel buffer a bit.
  CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, kCVAttachmentMode_ShouldPropagate);
  */

  CMVideoFormatDescriptionRef format;
  OSStatus error = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format);
  if (error != noErr) {
    NSLog(@"Couldn't determine format from pixel buffer, with error %d.", error);
    return NO;
  }

  CMFormatDescriptionRef modifiedFormat = NULL;

  // Make a new format based on the old format, that changes some extensions.
  FourCharCode codec = CMFormatDescriptionGetMediaSubType(format);
  CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format);
  CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(format);

  CFMutableDictionaryRef modifiedExtensions = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, extensions);

  // Force the ITU color primaries
  CFDictionarySetValue(modifiedExtensions, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020);

  // Force the HLG transfer function.
  CFDictionarySetValue(modifiedExtensions, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG);

  // Remove the ICC profile.
  CFDictionaryRemoveValue(modifiedExtensions, kCVImageBufferICCProfileKey);

  CMVideoFormatDescriptionCreate(kCFAllocatorDefault, codec, dimensions.width, dimensions.height, modifiedExtensions, &modifiedFormat);

  if (modifiedExtensions) {
    CFRelease(modifiedExtensions);
  }
  
  if (modifiedFormat) {
    format = modifiedFormat;
  }

  CMSampleBufferRef sampleBuffer = nil;
  error = CMSampleBufferCreateReadyWithImageBuffer(
      kCFAllocatorDefault, pixelBuffer, format, &kCMTimingInfoInvalid, &sampleBuffer);

  if (modifiedFormat) {
    CFRelease(modifiedFormat);
  }

  if (error != noErr) {
    NSLog(@"Couldn't recreate a CMSampleBuffer from the pixel buffer.");
    return NO;
  }

  // Since we don't have timing information for the sample, before we enqueue
  // it, we attach an attribute that specifies that the sample should be played
  // immediately.

  // There are two ways to make the sample appear immediately. They don't appear
  // to differ in effect, but we could make them into a toggle-able checkbox
  // if we wanted to.
  // 1) This is the display immediately method.
  CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
  if (!attachmentsArray || CFArrayGetCount(attachmentsArray) == 0) {
    NSLog(@"Newly created CMSampleBuffer doesn't have an attachments array.");
    return NO;
  }
  CFMutableDictionaryRef sample0Dictionary = (__bridge CFMutableDictionaryRef)(CFArrayGetValueAtIndex(attachmentsArray, 0));
  CFDictionarySetValue(sample0Dictionary, kCMSampleAttachmentKey_DisplayImmediately,
                       kCFBooleanTrue);

  // 2) This is the time-is-now method.
  /*
  CMTime nowTime = CMTimebaseGetTime(avLayer.controlTimebase);
  CMSampleBufferSetOutputPresentationTimeStamp(sampleBuffer, nowTime);
  */

  [avLayer enqueueSampleBuffer:sampleBuffer];
  return YES;
}

- (void)displayLayer:(CALayer*)layer {
  // If this is stale, early exit.
  if (layer != videoLayer) {
    return;
  }

  if (frameSurface) {
    layer.contents = (id)frameSurface;
  }
}

- (void)noMoreBuffers {
  if (CMTimeCompare(presentationTimeOfLastBuffer, kCMTimeInvalid) == 0) {
    return;
  }

  if (avLayer && lastModel.willRequestFramesRepeatedly) {
    // Stop requesting buffers.
    [avLayer stopRequestingMediaData];
  }

  // Get the time the frame(s) from the last buffer will be rendered, then loop
  // once we reach that time.
  [self restartAtTime:presentationTimeOfLastBuffer];
}

@end
