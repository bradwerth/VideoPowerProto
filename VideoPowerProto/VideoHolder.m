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
  VideoModel* lastModel;
  float aspectRatio;
  dispatch_queue_global_t queueToUse;
}

const int32_t kStoredBufferMax = 10;

- (void)awakeFromNib {
  // Treat this as our initialization method, and set properties we'll need to
  // act as a layer-backed view.
  contentLayer = nil;
  avLayer = nil;
  lastModel = nil;
  aspectRatio = 1.0f;
  queueToUse = dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0);

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

- (BOOL)handleDecodedFrame:(CMSampleBufferRef)buffer {
  //NSLog(@"handleDecodedFrame buffer is %@.", buffer);

  // Check for interesting buffer attachments.
  CFTypeRef attachment;

  // Should we post that we've consumed this buffer?
  if ((attachment = CMGetAttachment(buffer, kCMSampleBufferAttachmentKey_PostNotificationWhenConsumed, NULL))) {
    //NSLog(@"handleDecodedFrame post notification buffer.");
    CFNotificationCenterRef center = CFNotificationCenterGetLocalCenter();
    CFNotificationCenterPostNotification(center, kCMSampleBufferConsumerNotification_BufferConsumed , self, attachment, false);
  }

  // Is this the last frame from the media?
  if ((attachment = CMGetAttachment(buffer, kCMSampleBufferAttachmentKey_PermanentEmptyMedia, NULL))) {
    //NSLog(@"handleDecodedFrame last frame.");

    // Stop requesting frames.
    [avLayer stopRequestingMediaData];

    // Get the time this frame would be rendered, then loop once we reach that
    // time.
    CMTime timeToLoop = CMSampleBufferGetOutputPresentationTimeStamp(buffer);
    [self restartAtTime:timeToLoop];
    // No more frames, please.
    return NO;
  }

  // Beyond this, we only care about displayable frames.
  CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(buffer);
  BOOL canDisplay = !!format;
  if (!canDisplay) {
    // We want more frames.
    return YES;
  }

  if (lastModel.layerClass == LayerClassCALayer) {
    // Extract the image from the buffer.
    // TODO: the following call always returns nil, making this approach fail.
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(buffer);
    IOSurfaceRef surface = CVPixelBufferGetIOSurface((CVPixelBufferRef)imageBuffer);
    if (!surface) {
      return NO;
    }
    contentLayer.contents = (id)surface;
  } else if (lastModel.layerClass == LayerClassAVSampleBufferDisplayLayer) {
    assert(avLayer);

    // It's possible that our layer can't handle any more frames.
    if ([avLayer status] == AVQueuedSampleBufferRenderingStatusFailed) {
      [self recreateContentLayer];
      assert(avLayer);
    }

    if ([avLayer requiresFlushToResumeDecoding]) {
      [avLayer flush];
    }

    assert([avLayer isReadyForMoreMediaData]);
    [avLayer enqueueSampleBuffer:buffer];

    return [avLayer isReadyForMoreMediaData];
  }

  // We want more frames.
  return YES;
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

  // Remove content layer and all the sublayers of the backing layer.
  [contentLayer release];
  contentLayer = nil;
  avLayer = nil;
  self.layer.sublayers = nil;

  if (!lastModel) {
    return;
  }

  if (lastModel.layerClass == LayerClassCALayer) {
    NSLog(@"recreateContentLayer CALayer.");
    contentLayer = [[CALayer layer] retain];
  } else if (lastModel.layerClass == LayerClassAVSampleBufferDisplayLayer) {
    NSLog(@"recreateContentLayer AVSampleBufferDisplayLayer.");
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
    if (avLayer) {
      [avLayer requestMediaDataWhenReadyOnQueue:queueToUse usingBlock:^{
        [holder enqueueMoreFrames];
      }];
    }
  }];
}

- (void)centerContentLayer {
  if (!contentLayer) {
    return;
  }
  CGSize layerSize = self.layer.bounds.size;

  // First, see if we are height-limited.
  CGFloat requestedWidth = layerSize.height * aspectRatio;
  CGFloat requestedHeight = layerSize.height;
  if (requestedWidth > layerSize.width) {
    requestedWidth = layerSize.width;
    requestedHeight = layerSize.width / aspectRatio;
  }

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  contentLayer.position = CGPointMake((layerSize.width - requestedWidth) * 0.5f, (layerSize.height - requestedHeight) * 0.5f);
  contentLayer.bounds = CGRectMake(0.0f, 0.0f, requestedWidth, requestedHeight);
  [CATransaction commit];
}

- (BOOL)wantsMoreFrames {
  if (avLayer) {
    return [avLayer isReadyForMoreMediaData];
  }
  return YES;
}

- (void)enqueueMoreFrames {
  [self.controller requestFrames];
}

- (void)restartAtTime:(CMTime)targetTime {
  if (avLayer) {
    // Define a block that we'll use to reset the video.
    void (^loopBlock)(CFRunLoopTimerRef) = ^(CFRunLoopTimerRef timer) {
      [avLayer flush];
      CMTimebaseSetTime(avLayer.controlTimebase, CMTimeMake(0, 1));
      VideoHolder* holder = self;
      [avLayer requestMediaDataWhenReadyOnQueue:queueToUse usingBlock:^{
        [holder enqueueMoreFrames];
      }];
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

@end
