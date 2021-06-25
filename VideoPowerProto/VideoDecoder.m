//
//  VideoDecoder.m
//  VideoPowerProto
//
//  Created by Brad Werth on 6/15/21.
//

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

#import "VideoDecoder.h"
#import "MainViewController.h"
#import "VideoModel.h"

@implementation VideoDecoder

MainViewController* controller;
AVAsset* asset;
AVAssetReader* assetReader;
AVAssetReaderTrackOutput* assetOutput;

dispatch_queue_global_t queueToUse;

- (instancetype)initWithController:(MainViewController *)inController {
  self = [super init];
  controller = inController;
  //session = nil;
  asset = nil;
  assetReader = nil;
  assetOutput = nil;

  queueToUse = dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0);
  return self;
}

- (void)dealloc {
  [self stopDecode];
  [super dealloc];
}

- (void)stopDecode {
  if (assetReader) {
    [assetReader cancelReading];
    [assetReader release];
    assetReader = nil;
  }

  [assetOutput release];
  assetOutput = nil;

  [asset release];
  asset = nil;
}

- (void)resetWithModel:(VideoModel *)model {
  // Get rid of any existing decoding.
  [self stopDecode];

  NSError* error = nil;

  asset = [[model videoAsset] retain];

  assetReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
  if (assetReader == nil) {
    NSLog(@"AssetReader creation failed with error: %@.", error);
    return;
  }

  // Load the tracks asynchronously, and then process them. We capture self so
  // we can use it in the code block.
  VideoDecoder* decoder = self;
  [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
    [decoder handleTracks];
  }];
}

- (void)handleTracks {
  NSError* error = nil;
  AVKeyValueStatus status = [asset statusOfValueForKey:@"tracks" error:&error];
  if (status == AVKeyValueStatusFailed) {
    NSLog(@"Track loading failed with: %@.", error);
    return;
  }

  // Track property is loaded, so we can get the video tracks without blocking.
  AVAssetTrack* firstVideoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
  if (!firstVideoTrack) {
    NSLog(@"No video track.");
    return;
  }

  assetOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:firstVideoTrack outputSettings:nil];
  [assetReader addOutput:assetOutput];
  [assetReader startReading];

  // Kick off frame decode on the GCD queue. We capture self so we can use it
  // in the code block.
  VideoDecoder* decoder = self;
  dispatch_async(queueToUse, ^{
    [decoder processFrames];
  });
};

- (void)processFrames {
  // Retain the assetReader and the assetOutput for duration of this scope.
  [[assetReader retain] autorelease];
  [[assetOutput retain] autorelease];

  if (!assetReader || !assetOutput) {
    // We must have cancelled decode. Early exit.
    return;
  }

  // Capture as many sample buffers as we can.
  CMSampleBufferRef buffer;
  AVAssetReaderStatus status = [assetReader status];
  while (status == AVAssetReaderStatusReading) {
    buffer = [assetOutput copyNextSampleBuffer];
    if (buffer) {
      [controller handleDecodedFrame:buffer];
      CFRelease(buffer);
    }
    status = [assetReader status];
  }

  // Check status to see if we should stop requesting more frames.
  switch (status) {
    case AVAssetReaderStatusFailed:
    case AVAssetReaderStatusCancelled:
      // Stop reading frames.
      return;
      break;
    default:
      // Do nothing.
      break;
  };

  // If we get this far, we should schedule ourself to run again on the queue.
  // Kick off frame decode on the GCD queue. We capture self so we can use it
  // in the code block.
  VideoDecoder* decoder = self;
  dispatch_async(queueToUse, ^{
    [decoder processFrames];
  });
}

@end
