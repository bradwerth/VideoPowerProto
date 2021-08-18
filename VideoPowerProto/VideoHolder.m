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
  // contentLayer is a retained reference to the layer that actually displays
  // the video content.
  CALayer* contentLayer;
  // avLayer is an unretained alias of contentLayer that indicates we're using
  // this type of layer.
  AVSampleBufferDisplayLayer* avLayer;
  // frameImage is the image content displayed by the contentLayer, if we are
  // being fed frames directly.
  CGImageRef frameImage;
  NSLock* frameImageLock;
  // frameConversionContext is used to convert surfaces into frame images.
  CIContext* frameConversionContext;
  
  VideoModel* lastModel;
  float aspectRatio;
  dispatch_queue_global_t queueToUse;

  CMTime presentationTimeOfLastBuffer;
}

const int32_t kStoredBufferMax = 10;

- (void)awakeFromNib {
  // Treat this as our initialization method, and set properties we'll need to
  // act as a layer-backed view.
  contentLayer = nil;
  avLayer = nil;
  frameImage = nil;
  frameImageLock = [[NSLock alloc] init];
  frameConversionContext = [[CIContext alloc] init];
  lastModel = nil;
  aspectRatio = 1.0f;
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
    [holder centerContentLayer];
  }];
}

- (void)resetWithModel:(VideoModel* _Nullable)model {
  // Copy the model to lock in its values, then release the old model.
  VideoModel *oldModel = lastModel;
  lastModel = [model copy];
  [oldModel release];

  [self recreateContentLayer];
}

- (void)recreateContentLayer {
  // Stop any requests from our last model.
  if (avLayer) {
    [avLayer stopRequestingMediaData];
  }

  presentationTimeOfLastBuffer = kCMTimeInvalid;

  // Remove content layer and all the sublayers of the backing layer.
  [contentLayer release];
  contentLayer = nil;
  avLayer = nil;
  self.layer.sublayers = nil;

  [frameImageLock lock];
  if (frameImage) {
    CFRelease(frameImage);
  }
  frameImage = nil;
  [frameImageLock unlock];

  if (!lastModel) {
    return;
  }

  if (lastModel.layerClass == LayerClassCALayer) {
    //NSLog(@"recreateContentLayer CALayer.");
    contentLayer = [[CALayer layer] retain];
    contentLayer.delegate = (id)self;
    contentLayer.needsDisplayOnBoundsChange = YES;
  } else if (lastModel.layerClass == LayerClassAVSampleBufferDisplayLayer) {
    //NSLog(@"recreateContentLayer AVSampleBufferDisplayLayer.");
    avLayer = [[AVSampleBufferDisplayLayer layer] retain];
    CMTimebaseRef timebase;
    CMTimebaseCreateWithMasterClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &timebase);
    CMTimebaseSetRate(timebase, 1.0f);
    avLayer.controlTimebase = timebase;
    contentLayer = avLayer;
  }

  contentLayer.position = NSZeroPoint;
  contentLayer.anchorPoint = NSZeroPoint;
  contentLayer.contentsGravity = kCAGravityTopLeft;
  contentLayer.contentsScale = 1;
  contentLayer.bounds = NSMakeRect(0.0f, 0.0f, 16.0f, 9.0f);
  contentLayer.edgeAntialiasingMask = 0;
  contentLayer.opaque = YES;

  [self.layer addSublayer:contentLayer];

  VideoHolder* holder = self;
  // Figure out the size of the video in the model, then center the content
  // and start requesting frames.
  [lastModel waitForVideoAssetFirstTrack:^(AVAssetTrack* track) {
    if (!track) {
      return;
    }

    CGSize trackSize = track.naturalSize;
    if (trackSize.width >= 0.0 && trackSize.height >= 0.0) {
      aspectRatio = trackSize.width / trackSize.height;
    } else {
      aspectRatio = 16.0f / 9.0f;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      [holder centerContentLayer];
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

- (CALayer*)detachContentLayer {
  self.layer.sublayers = nil;
  return contentLayer;
}

- (void)reattachContentLayer {
  [self.layer addSublayer:contentLayer];
  [self centerContentLayer];
}

- (void)enqueueMoreFrames {
  [self.controller requestFrames];
}

- (void)centerContentLayer {
  if (!contentLayer) {
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
  contentLayer.position = CGPointMake((viewSize.width - requestedWidth) * 0.5f, (viewSize.height - requestedHeight) * 0.5f);
  contentLayer.bounds = CGRectMake(0.0f, 0.0f, requestedWidth, requestedHeight);
  [CATransaction commit];
}

- (BOOL)wantsMoreFrames {
  if (avLayer) {
    return [avLayer isReadyForMoreMediaData];
  }
  return YES;
}

- (BOOL)handleBuffer:(CMSampleBufferRef)buffer {
  if (!lastModel) {
    return NO;
  }
  assert(lastModel.canHandleBuffers);

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
      [self recreateContentLayer];
      assert(avLayer);
    }

    if ([avLayer requiresFlushToResumeDecoding]) {
      [avLayer flush];
    }

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
  // We might have a stale frameImage. If we do, capture it and release it
  // after we have updated frameImage.
  [frameImageLock lock];
  CGImageRef staleFrameImage = frameImage;

  // Convert the surface into a CGImageRef and store it as our frameImage. We
  // do this by going through CIImage.
  CIImage* image = [CIImage imageWithIOSurface:surface];
  frameImage = [frameConversionContext createCGImage:image fromRect:image.extent];
  [frameImageLock unlock];

  if (staleFrameImage) {
    CFRelease(staleFrameImage);
  }

  CALayer* currentContentLayer = [contentLayer retain];
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([currentContentLayer superlayer]) {
      [currentContentLayer setNeedsDisplay];
    }
    [currentContentLayer release];
  });
  return YES;
}

- (void)displayLayer:(CALayer*)layer {
  // If this is stale, early exit.
  if (layer != contentLayer) {
    return;
  }

  [frameImageLock lock];
  if (frameImage) {
    // Figure out the correct scale to display this frame. Since the layer is
    // scaled to the aspect ratio of the content, we can just compute this based
    // on the width of the frame divided by the width of the layer.
    CGFloat scale = CGImageGetWidth(frameImage) / layer.bounds.size.width;
    layer.contentsScale = scale;
    layer.contents = (id)frameImage;

    // We don't need to hold onto frameImage any longer.
    CFRelease(frameImage);
    frameImage = nil;
  }
  [frameImageLock unlock];
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
