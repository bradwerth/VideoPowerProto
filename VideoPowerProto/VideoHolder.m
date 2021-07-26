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
  //CMSampleBufferRef emptyFrame;
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
  //emptyFrame = nil;
  lastModel = nil;
  aspectRatio = 1.0f;
  queueToUse = dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0);

  self.wantsLayer = YES;

  // Set some initial properties on our backing layer.
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
    NSLog(@"handleDecodedFrame post notification buffer.");
    CFNotificationCenterRef center = CFNotificationCenterGetLocalCenter();
    CFNotificationCenterPostNotification(center, kCMSampleBufferConsumerNotification_BufferConsumed , self, attachment, false);
  }

  // Is this the last frame from the media?
  if ((attachment = CMGetAttachment(buffer, kCMSampleBufferAttachmentKey_PermanentEmptyMedia, NULL))) {
    NSLog(@"handleDecodedFrame last frame.");
    [self restartAfterLastFrameRendered];
    return NO;
  }

  // Beyond this, we only care about displayable frames.
  CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(buffer);
  BOOL canDisplay = !!format;
  if (!canDisplay) {
    // We want more frames.
    return YES;
  }

  // Detect if the buffer contains a keyframe.
  BOOL containsKeyframe = NO;
  CMItemCount sampleCount = CMSampleBufferGetNumSamples(buffer);
  assert(sampleCount > 0);
  CFArrayRef sampleAttachments = CMSampleBufferGetSampleAttachmentsArray(buffer, NO);
  if (sampleAttachments) {
    for (CFIndex i = 0; i < sampleCount; ++i) {
      CFDictionaryRef dict = CFArrayGetValueAtIndex(sampleAttachments, i);
      assert(dict);
      CFBooleanRef dependsRef = CFDictionaryGetValue(dict, kCMSampleAttachmentKey_DependsOnOthers);
      Boolean dependsOnOthers = CFBooleanGetValue(dependsRef);
      if (!dependsOnOthers) {
        containsKeyframe = YES;
        break;
      }
    }
  }

  /*
  // If we don't have an emptyFrame, create one in this format.
  if (!emptyFrame) {
    CMSampleTimingInfo timing;
    timing.duration = CMTimeMake(0, 1);
    timing.decodeTimeStamp = kCMTimeInvalid;
    timing.presentationTimeStamp = CMTimeMake(0, 1);
    CMSampleBufferCreateReady(kCFAllocatorDefault, NULL, format, 0, 1, &timing, 0, NULL, &emptyFrame);
    assert(emptyFrame);
    CMSetAttachment(emptyFrame, kCMSampleBufferAttachmentKey_EmptyMedia, kCFBooleanTrue, kCMAttachmentMode_ShouldNotPropagate);
  }
  */

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

    /*
    // If we posted a keyframe, stop requesting frames.
    if (containsKeyframe) {
      return NO;
    }
    */

    return [avLayer isReadyForMoreMediaData];
  }

  // We want more frames.
  return YES;
}

- (void)resetWithModel:(VideoModel* _Nullable)model {
  /*
  // Get rid of our emptyFrame.
  if (emptyFrame) {
    CFRelease(emptyFrame);
    emptyFrame = nil;
  }
  */

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

- (void)restartAfterLastFrameRendered {
  if (avLayer) {
    [avLayer stopRequestingMediaData];
    //[avLayer enqueueSampleBuffer:emptyFrame];

    // Ideally these steps should be delayed until we've displayed the last
    // frame.
    [avLayer flush];
    CMTimebaseSetTime(avLayer.controlTimebase, CMTimeMake(0, 1));
    VideoHolder* holder = self;
    [avLayer requestMediaDataWhenReadyOnQueue:queueToUse usingBlock:^{
      [holder enqueueMoreFrames];
    }];
  }
}

@end
