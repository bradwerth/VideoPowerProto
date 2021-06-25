//
//  VideoHolder.m
//  video-low-power
//
//  Created by Brad Werth on 6/10/21.
//

#import <AVKit/AVKit.h>

#import "VideoHolder.h"
#import "VideoModel.h"

@implementation VideoHolder

// Retained reference to the layer that actually displays the video content.
CALayer* contentLayer;
VideoModel* lastModel;
float aspectRatio;

- (void)awakeFromNib {
  // Treat this as our initialization method, and set properties we'll need to
  // act as a layer-backed view.
  contentLayer = nil;
  lastModel = nil;

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

- (void)handleDecodedFrame:(CMSampleBufferRef)buffer {
  CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(buffer);
  if (!format) {
    NSLog(@"Ignoring sample buffer with no format descriptor: %@.", buffer);
    return;
  }

  if (lastModel.layerClass == LayerClassCALayer) {
    // Extract the image from the buffer.
    // TODO: the following call always returns nil, making this approach fail.
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(buffer);
    IOSurfaceRef surface = CVPixelBufferGetIOSurface((CVPixelBufferRef)imageBuffer);
    if (!surface) {
      return;
    }
    contentLayer.contents = (id)surface;
  } else if (lastModel.layerClass == LayerClassAVSampleBufferDisplayLayer) {
    AVSampleBufferDisplayLayer* avLayer = (AVSampleBufferDisplayLayer*)contentLayer;
    [avLayer enqueueSampleBuffer:buffer];
  }
}

- (void)resetWithModel:(VideoModel*)model {
  lastModel = model;

  // Remove content layer and all the sublayers of the backing layer.
  [contentLayer release];
  self.layer.sublayers = nil;

  if (model.layerClass == LayerClassCALayer) {
    NSLog(@"Resetting with CALayer.");
    contentLayer = [[CALayer layer] retain];
  } else if (model.layerClass == LayerClassAVSampleBufferDisplayLayer) {
    NSLog(@"Resetting with AVSampleBufferDisplayLayer.");
    contentLayer = [[AVSampleBufferDisplayLayer layer] retain];
  }

  contentLayer.position = NSZeroPoint;
  contentLayer.anchorPoint = NSZeroPoint;
  contentLayer.contentsGravity = kCAGravityTopLeft;
  contentLayer.contentsScale = 1;
  contentLayer.bounds = NSMakeRect(0.0f, 0.0f, 16.0f, 9.0f);
  contentLayer.edgeAntialiasingMask = 0;
  contentLayer.opaque = YES;

  [self.layer addSublayer:contentLayer];

  // Figure out the size of the video in the model, then center the content.
  VideoHolder* holder = self;
  [model waitForVideoAssetFirstTrack:^(AVAssetTrack* track) {
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
  }];
}

- (void)centerContentLayer {
  assert(contentLayer);
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

@end
