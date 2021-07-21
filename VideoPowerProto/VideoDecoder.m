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
  BOOL readyToRead;
  AVAssetReader* assetReader;
  AVAssetReaderTrackOutput* assetOutput;

  dispatch_queue_t serialDecoderQueue;
}

- (instancetype)initWithController:(MainViewController *)inController {
  self = [super init];
  controller = inController;
  asset = nil;
  firstVideoTrack = nil;
  readyToRead = NO;
  assetReader = nil;
  assetOutput = nil;

  serialDecoderQueue = dispatch_queue_create("VideoPowerProto.SerialDecoder", DISPATCH_QUEUE_SERIAL);
  return self;
}

- (void)dealloc {
  VideoDecoder* decoder = self;
  dispatch_async(serialDecoderQueue, ^{
    // Get rid of any existing decoding.
    [decoder stopDecode];
  });
  dispatch_release(serialDecoderQueue);
  [super dealloc];
}

- (void)stopDecode {
  readyToRead = NO;

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

- (void)resetWithModel:(VideoModel *)model {
  // We have to do this asynchronously on the same serial queue we use for the
  // decoding operations, since it manipulates our asset reading structures.
  AVAsset* retainedAsset = [[model videoAsset] retain];

  VideoDecoder* decoder = self;
  dispatch_async(serialDecoderQueue, ^{
    // Get rid of any existing decoding.
    [decoder stopDecode];

    decoder->asset = retainedAsset;

    // Load the tracks asynchronously, and then process them.
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
      [decoder handleTracks];
    }];
  });
}

- (void)handleTracks {
  NSError* error = nil;
  AVKeyValueStatus status = [asset statusOfValueForKey:@"tracks" error:&error];
  if (status == AVKeyValueStatusFailed) {
    NSLog(@"Track loading failed with: %@.", error);
    return;
  }

  // Track property is loaded, so we can get the video tracks without blocking.
  firstVideoTrack = [[[asset tracksWithMediaType:AVMediaTypeVideo] firstObject] retain];
  if (!firstVideoTrack) {
    NSLog(@"No video track.");
    return;
  }

  VideoDecoder* decoder = self;
  dispatch_async(serialDecoderQueue, ^{
    [decoder readAssetFromBeginning];
  });
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
  readyToRead = YES;
  return YES;
}

- (void)requestFrames {
  if (!readyToRead) {
    // Too early! No reader available yet.
    return;
  }

  VideoDecoder* decoder = self;
  dispatch_async(serialDecoderQueue, ^{
    [decoder generateFrames];
  });
}

- (void)generateFrames {
  // If not ready to read, exit.
  if (!readyToRead) {
    return;
  }

  assert(assetReader);
  assert(assetOutput);

  // Capture as many sample buffers as we can.
  BOOL wantsMoreFrames = [controller wantsMoreFrames];
  while (wantsMoreFrames) {
    // Grab frames while we can, as long as our controller wants them.
    AVAssetReaderStatus status = [assetReader status];
    while (status == AVAssetReaderStatusReading) {
      CMSampleBufferRef buffer = [assetOutput copyNextSampleBuffer];
      if (buffer) {
        wantsMoreFrames = [controller handleDecodedFrame:buffer];
        CFRelease(buffer);
      }
      status = [assetReader status];
      if (!wantsMoreFrames) {
        break;
      }
    }

    // Check status to see how to proceed.
    switch (status) {
      case AVAssetReaderStatusCompleted:
      case AVAssetReaderStatusFailed:
      case AVAssetReaderStatusCancelled:
      case AVAssetReaderStatusUnknown:
        // That's enough for now. Our controller can try again.
        readyToRead = NO;
        return;
      default:
        // The only reason we should reach this is if we are still reading and
        // our controller doesn't want any more frames.
        assert(status == AVAssetReaderStatusReading);
        assert(!wantsMoreFrames);
        break;
    };
  }
}

@end
