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
  BOOL canHandleBuffers;
  AVAsset* asset;
  AVAssetTrack* firstVideoTrack;
  AVAssetReader* assetReader;
  AVAssetReaderTrackOutput* assetOutput;
  VTDecompressionSessionRef decompressor;
}

- (instancetype)initWithController:(MainViewController *)inController {
  self = [super init];
  controller = inController;
  canHandleBuffers = NO;
  asset = nil;
  firstVideoTrack = nil;
  assetReader = nil;
  assetOutput = nil;
  decompressor = nil;
  return self;
}

- (void)dealloc {
  // Get rid of any existing decoding.
  [self stopDecode];
  [super dealloc];
}

- (void)stopDecode {
  [self stopDecompressor];

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

- (void)resetWithModel:(nullable VideoModel*)model completionHandler:(void (^)(BOOL))block {
  // Get rid of any existing decoding.
  [self stopDecode];

  canHandleBuffers = model.canHandleBuffers;

  asset = [[model videoAsset] retain];
  if (asset) {
    // Load the tracks asynchronously, and then process them.
    VideoDecoder* decoder = self;
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
      [decoder handleTracksWithCompletionHandler:block];
    }];
  } else {
    // Call the block.
    block(NO);
  }
}

- (void)handleTracksWithCompletionHandler:(void (^)(BOOL))block {
  NSError* error = nil;
  AVKeyValueStatus status = [asset statusOfValueForKey:@"tracks" error:&error];
  if (status == AVKeyValueStatusFailed) {
    NSLog(@"Track loading failed with: %@.", error);
    block(NO);
    return;
  }

  // Track property is loaded, so we can get the video tracks without blocking.
  firstVideoTrack = [[[asset tracksWithMediaType:AVMediaTypeVideo] firstObject] retain];
  if (!firstVideoTrack) {
    NSLog(@"No video track.");
    block(NO);
    return;
  }

  // Define a block for triggering reading and reporting success, that we can
  // either call ourselves, or pass as a completion handler.
  void (^readBlock)(BOOL) = ^(BOOL success) {
    BOOL readSuccess = (success && [self readAssetFromBeginning]);
    block(readSuccess);
  };

  BOOL needToDecompressBuffers = !canHandleBuffers;
  if (needToDecompressBuffers) {
    // Load the formatDescriptions asynchronously, and then process them.
    VideoDecoder* decoder = self;
    [firstVideoTrack loadValuesAsynchronouslyForKeys:@[@"formatDescriptions"] completionHandler:^{
      [decoder handleFormatsWithCompletionHandler:readBlock];
    }];
    return;
  }

  // We don't need to setup our decompressor, so call our readBlock directly.
  readBlock(YES);
}

- (void)handleFormatsWithCompletionHandler:(void (^)(BOOL))block {
  assert(firstVideoTrack);
  NSUInteger formatCount = firstVideoTrack.formatDescriptions.count;
  if (formatCount == 0) {
    NSLog(@"No format description in first video track.");
    block(NO);
    return;
  }

  if (formatCount > 1) {
    NSLog(@"WARNING: We will only decode buffers with the first reported format.");
  }

  CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)firstVideoTrack.formatDescriptions[0];
  VTDecompressionOutputCallbackRecord callback = {DecompressorCallback, self};
  OSStatus error = VTDecompressionSessionCreate(kCFAllocatorDefault, format, NULL, NULL, &callback, &decompressor);
  if (!decompressor) {
    NSLog(@"Failed to create decompression session with error %d.", error);
  }
  assert(error == noErr);
  CFRetain(decompressor);

  block(YES);
}

// Define a C-style callback for our decompressor.
void DecompressorCallback(void *decompressionOutputRefCon, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef image, CMTime presentationTimeStamp, CMTime presentationDuration) {
  VideoDecoder* decoder = (VideoDecoder*)decompressionOutputRefCon;
  [decoder outputImageAsFrame:image];
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

- (void)generateBuffers {
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
    //NSLog(@"generateBuffers: start on %@.", [NSThread currentThread]);
    while (wantsMoreFrames) {
      // Grab frames while we can, as long as our controller wants them.
      AVAssetReaderStatus status = [reader status];
      while (status == AVAssetReaderStatusReading) {
        CMSampleBufferRef buffer = [output copyNextSampleBuffer];
        if (buffer) {
          if (canHandleBuffers) {
            wantsMoreFrames = [controller handleBuffer:buffer];
          } else {
            wantsMoreFrames = [self decompressBufferIntoFrames:buffer];
          }
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
    //NSLog(@"generateBuffers: end.");
  }
}

- (void)stopDecompressor {
  if (decompressor) {
    VTDecompressionSessionInvalidate(decompressor);
    CFRelease(decompressor);
    decompressor = nil;
  }
}

- (BOOL)decompressBufferIntoFrames:(CMSampleBufferRef)buffer {
  assert(decompressor);
  BOOL wantsMoreBuffers = YES;

  // Only attempt to decode buffers with sample data.
  CMItemCount sampleCount = CMSampleBufferGetNumSamples(buffer);
  if (sampleCount == 0) {
    return YES;
  }

  VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression | kVTDecodeFrame_EnableTemporalProcessing;
  OSStatus error = VTDecompressionSessionDecodeFrame(decompressor, buffer, flags, buffer, NULL);
  BOOL decodeSuccess = (error == noErr);
  wantsMoreBuffers &= decodeSuccess;
  if (!decodeSuccess) {
    NSLog(@"decompressBufferIntoFrames failed to decode buffer %@.", buffer);
  }

  //return wantsMoreBuffers;
  return NO;
}

- (void)outputImageAsFrame:(CVImageBufferRef)image {
  // See if we can get an IOSurface from the pixel buffer.
  IOSurfaceRef surface = CVPixelBufferGetIOSurface(image);
  if (!surface) {
    return;
  }
  [controller handleFrame:surface];
}

@end
