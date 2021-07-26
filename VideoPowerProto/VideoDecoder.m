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

@implementation VideoDecoder {
  MainViewController* controller;
  AVAsset* asset;
  AVAssetTrack* firstVideoTrack;
  AVAssetReader* assetReader;
  AVAssetReaderTrackOutput* assetOutput;
}

- (instancetype)initWithController:(MainViewController *)inController {
  self = [super init];
  controller = inController;
  asset = nil;
  firstVideoTrack = nil;
  assetReader = nil;
  assetOutput = nil;
  return self;
}

- (void)dealloc {
  // Get rid of any existing decoding.
  [self stopDecode];
  [super dealloc];
}

- (void)stopDecode {
  if (assetReader) {
    [assetReader cancelReading];
  }
  [assetReader release];
  assetReader = nil;

  [assetOutput release];
  assetOutput = nil;

  [firstVideoTrack release];
  firstVideoTrack = nil;

  [asset release];
  asset = nil;
}

- (void)resetWithModel:(nullable VideoModel*)model completionHandler:(nullable void (^)(bool))block {
  // Get rid of any existing decoding.
  [self stopDecode];

  asset = [[model videoAsset] retain];
  if (asset) {
    // Load the tracks asynchronously, and then process them.
    VideoDecoder* decoder = self;
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
      [decoder handleTracksWithCompletionHandler:block];
    }];
  } else {
    // Call the block, if it is non-null.
    if (block) {
      block(NO);
    }
  }
}

- (void)handleTracksWithCompletionHandler:(nullable void (^)(bool))block {
  NSError* error = nil;
  AVKeyValueStatus status = [asset statusOfValueForKey:@"tracks" error:&error];
  if (status == AVKeyValueStatusFailed) {
    NSLog(@"Track loading failed with: %@.", error);
    if (block) {
      block(NO);
    }
    return;
  }

  // Track property is loaded, so we can get the video tracks without blocking.
  firstVideoTrack = [[[asset tracksWithMediaType:AVMediaTypeVideo] firstObject] retain];
  if (!firstVideoTrack) {
    NSLog(@"No video track.");
    if (block) {
      block(NO);
    }
    return;
  }

  BOOL success = [self readAssetFromBeginning];
  if (block) {
    block(success);
  }
}

- (BOOL)readAssetFromBeginning {
  assert(firstVideoTrack);

  if (assetReader) {
    [assetReader cancelReading];
  }
  [assetReader release];
  assetReader = nil;

  [assetOutput release];
  assetOutput = nil;

  NSError* error = nil;
  assetReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
  if (assetReader == nil) {
    NSLog(@"AssetReader creation failed with error: %@.", error);
    return NO;
  }

  assetOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:firstVideoTrack outputSettings:nil];
  assetOutput.alwaysCopiesSampleData = NO;
  [assetReader addOutput:assetOutput];
  [assetReader startReading];
  return YES;
}

- (void)generateFrames {
  // This function is called from other threads, and has to be sensitive to
  // our asset structures being released during the call.
  @autoreleasepool {
    AVAssetReader* reader = [[assetReader retain] autorelease];
    AVAssetReaderOutput* output = [[assetOutput retain] autorelease];
    if (!reader || !output) {
      return;
    }

    // Capture as many sample buffers as we can.
    BOOL wantsMoreFrames = [controller wantsMoreFrames];
    //NSLog(@"generateFrames: start on %@.", [NSThread currentThread]);
    while (wantsMoreFrames) {
      // Grab frames while we can, as long as our controller wants them.
      AVAssetReaderStatus status = [reader status];
      while (status == AVAssetReaderStatusReading) {
        CMSampleBufferRef buffer = [output copyNextSampleBuffer];
        if (buffer) {
          //NSLog(@"generateFrames: pushing frame.");
          wantsMoreFrames = [controller handleDecodedFrame:buffer];
          CFRelease(buffer);
        }
        status = [reader status];
        if (!wantsMoreFrames) {
          break;
        }
      }

      // Check status to see how to proceed.
      switch (status) {
        case AVAssetReaderStatusCompleted: {
          BOOL didReset = [self readAssetFromBeginning];
          if (!didReset) {
            return;
          }
          // Re-establish our local asset structures.
          reader = [[assetReader retain] autorelease];
          output = [[assetOutput retain] autorelease];
          if (!reader || !output) {
            return;
          }
          break;
        }
        case AVAssetReaderStatusFailed:
        case AVAssetReaderStatusCancelled:
        case AVAssetReaderStatusUnknown:
          // That's enough for now. Our controller can try again.
          return;
        default:
          // The only reason we should reach this is if we are still reading and
          // our controller doesn't want any more frames.
          assert(status == AVAssetReaderStatusReading);
          assert(!wantsMoreFrames);
          break;
      };
    }
    //NSLog(@"generateFrames: end.");
  }
}

@end
