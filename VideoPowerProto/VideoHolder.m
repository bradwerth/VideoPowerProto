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
  self.layer.bounds = self.bounds;
  self.layer.anchorPoint = NSZeroPoint;
  self.layer.contentsGravity = kCAGravityTopLeft;
  self.layer.edgeAntialiasingMask = 0;
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
  contentLayer.bounds = self.layer.bounds;
  contentLayer.edgeAntialiasingMask = 0;
  contentLayer.opaque = YES;

  [self.layer addSublayer:contentLayer];

  self.needsDisplay = YES;
}

@end
