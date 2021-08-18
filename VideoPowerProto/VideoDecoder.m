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
  VideoModel* lastModel;
  AVAsset* asset;
  AVAssetTrack* firstVideoTrack;
  AVAssetReader* assetReader;
  AVAssetReaderTrackOutput* assetOutput;
  VTDecompressionSessionRef decompressor;
  CFAbsoluteTime timeAtStart;
  CFMutableArrayRef frameImages;
  CFMutableArrayRef frameTimestamps;
  BOOL frameTimerActive;
  dispatch_queue_global_t frameTimerQueue;
  dispatch_source_t frameTimerSource;
}

static const double MAX_FRAME_RATE = 60.0;
static const double FRAME_INTERVAL = 1.0 / MAX_FRAME_RATE;
static const int64_t FRAME_INTERVAL_NS = (int64_t)(FRAME_INTERVAL * 1e9);
static const int64_t FRAME_INTERVAL_LEEWAY_NS = 1000;
static const double SECONDS_OF_FRAMES_TO_BUFFER = 1.0;
static const CFIndex MAX_FRAMES_TO_HOLD = (CFIndex)(SECONDS_OF_FRAMES_TO_BUFFER * MAX_FRAME_RATE);

- (instancetype)initWithController:(MainViewController *)inController {
  self = [super init];
  controller = inController;
  lastModel = nil;
  asset = nil;
  firstVideoTrack = nil;
  assetReader = nil;
  assetOutput = nil;
  decompressor = nil;
  timeAtStart = 0;
  frameImages = nil;
  frameTimestamps = nil;

  // Create our frame timer, and start it up in a suspended state.
  frameTimerActive = NO;
  frameTimerQueue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
  frameTimerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, frameTimerQueue);
  dispatch_source_set_timer(frameTimerSource, DISPATCH_TIME_NOW, FRAME_INTERVAL_NS, FRAME_INTERVAL_LEEWAY_NS);
  dispatch_set_context(frameTimerSource, self);
  dispatch_source_set_event_handler_f(frameTimerSource, frameTimerCallback);
  
  return self;
}

- (void)dealloc {
  // Get rid of any existing decoding.
  [self stopDecode];

  [lastModel release];
  lastModel = nil;

  [asset release];
  asset = nil;

  dispatch_resume(frameTimerSource);
  dispatch_release(frameTimerSource);
  dispatch_release(frameTimerQueue);
  [super dealloc];
}

- (void)stopDecode {
  [self stopDecompressor];

  if (frameTimerActive) {
    dispatch_suspend(frameTimerSource);
  }
  frameTimerActive = NO;

  if (frameImages) {
    CFRelease(frameImages);
  }
  frameImages = nil;

  if (frameTimestamps) {
    CFRelease(frameTimestamps);
  }
  frameTimestamps = nil;

  if (assetReader) {
    [assetReader cancelReading];
  }
  [assetReader release];
  assetReader = nil;

  [assetOutput release];
  assetOutput = nil;

  [firstVideoTrack release];
  firstVideoTrack = nil;
}

- (void)resetWithModel:(nullable VideoModel*)model completionHandler:(void (^)(BOOL))block {
  // Get rid of any existing decoding.
  [self stopDecode];

  // Copy the model to lock in its values, then release the old model.
  VideoModel *oldModel = lastModel;
  lastModel = [model copy];
  [oldModel release];

  if (!lastModel) {
    block(NO);
    return;
  }

  asset = [[lastModel videoAsset] retain];
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
  assert(lastModel);
  assert(asset);

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

  BOOL needToDecompressBuffers = !lastModel.canHandleBuffers;
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
    block(NO);
    return;
  }
  assert(error == noErr);
  CFRetain(decompressor);

  // Setup our frame storage arrays.
  frameImages = CFArrayCreateMutable(kCFAllocatorDefault, MAX_FRAMES_TO_HOLD, &kCFTypeArrayCallBacks);
  frameTimestamps = CFArrayCreateMutable(kCFAllocatorDefault, MAX_FRAMES_TO_HOLD, &kCFTypeArrayCallBacks);

  frameTimerActive = YES;
  dispatch_resume(frameTimerSource);

  block(YES);
}

// Define a C-style callback for our decompressor.
void DecompressorCallback(void *decompressionOutputRefCon, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef image, CMTime presentationTimestamp, CMTime presentationDuration) {
  VideoDecoder* decoder = (VideoDecoder*)decompressionOutputRefCon;
  [decoder storeImage:image withTimestamp:presentationTimestamp];
}

- (void)storeImage:(CVImageBufferRef)image withTimestamp:(CMTime)ts {
  assert(frameImages);
  assert(frameTimestamps);
  CFAbsoluteTime playbackTime = timeAtStart + CMTimeGetSeconds(ts);
  CFDateRef playbackDate = CFDateCreate(kCFAllocatorDefault, playbackTime);

  CFArrayAppendValue(frameImages, image);
  CFArrayAppendValue(frameTimestamps, playbackDate);
  CFRelease(playbackDate);

  //NSLog(@"storeImage: stuffing frame at %f and now there are %ld/%ld frames.", playbackTime, (long)CFArrayGetCount(frameTimestamps), (long)MAX_FRAMES_TO_HOLD);
}

void frameTimerCallback(void* context) {
  VideoDecoder* decoder = (VideoDecoder*)context;
  [decoder processFrameImages];
}

- (void)processFrameImages {
  assert(frameTimerActive);

  // This is called concurrently, so ensure that the structures we need are
  // retained for the duration of the call.
  CFMutableArrayRef timestamps = nil;
  if (frameTimestamps) {
    timestamps = (__bridge CFMutableArrayRef)CFRetain(frameTimestamps);
  }
  if (!timestamps) {
    return;
  }

  CFMutableArrayRef images = nil;
  if (frameImages) {
    images = (__bridge CFMutableArrayRef)CFRetain(frameImages);
  }
  if (!images) {
    CFRelease(timestamps);
    return;
  }

  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

  // Loop through all the frames we're holding and output the latest one that
  // has a timestamp before now (if any).
  CFIndex frameCount = CFArrayGetCount(timestamps);

  if (frameCount > MAX_FRAMES_TO_HOLD) {
    // Dump oldest frames to bring us back down to the maximum.
    CFIndex lastStaleFrame = (frameCount - MAX_FRAMES_TO_HOLD) - 1;
    //NSLog(@"frameTimerCallback dumping %ld stale frames.", (long)(lastStaleFrame + 1));
    CFArrayReplaceValues(images, CFRangeMake(0, lastStaleFrame), NULL, 0);
    CFArrayReplaceValues(timestamps, CFRangeMake(0, lastStaleFrame), NULL, 0);
    frameCount = MAX_FRAMES_TO_HOLD;
  }

  CFIndex f = 0;
  while (f < frameCount) {
    CFDateRef date = CFArrayGetValueAtIndex(timestamps, f);
    CFAbsoluteTime ts = CFDateGetAbsoluteTime(date);
    if (ts > now) {
      // This frame is too new!
      break;
    }
    f++;
  }

  // The previous frame we saw is the latest one that we can output.
  CFIndex latestFrameIndex = f - 1;
  //NSLog(@"frameTimerCallback latestFrameIndex is %ld.", (long)latestFrameIndex);
  if (latestFrameIndex >= 0) {
    CVImageBufferRef image = (CVImageBufferRef)CFArrayGetValueAtIndex(images, latestFrameIndex);
    [self outputImageAsFrame:image];

    // Get rid of all frames up to and including the one we just output.
    CFArrayReplaceValues(images, CFRangeMake(0, latestFrameIndex), NULL, 0);
    CFArrayReplaceValues(timestamps, CFRangeMake(0, latestFrameIndex), NULL, 0);
  }

  CFRelease(timestamps);
  CFRelease(images);
}

- (BOOL)readAssetFromBeginning {
  assert(lastModel);
  assert(firstVideoTrack);

  if (!lastModel.canHandleBuffers) {
    // Reset our timeAtStart.
    timeAtStart = CFAbsoluteTimeGetCurrent();

    // We don't dump frames we're holding, because stale ones could still be
    // displayed.
  }

  if (assetReader) {
    [assetReader cancelReading];
  }
  [assetReader release];
  assetReader = nil;

  [assetOutput release];
  assetOutput = nil;

  NSError* error = nil;
  AVAssetReader* reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
  if (reader == nil) {
    NSLog(@"AssetReader creation failed with error: %@.", error);
    return NO;
  }

  NSDictionary<NSString*, id>* dict = [NSMutableDictionary<NSString*, id> dictionary];

  // Always specify IOSurface key. Using a blank dictionary lets the OS decide
  // the best way to allocate IOSurfaces.
  [dict setValue:[NSDictionary dictionary] forKey:(__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey];

  // Handle pixel format keys.
  OSType pixelFormat;
  switch (lastModel.format) {
    case FormatUnspecified:
      pixelFormat = 0;
      break;
    case Format422YpCbCr8:
      pixelFormat = kCVPixelFormatType_422YpCbCr8;
      break;
    case Format420YpCbCr8BiPlanarVideoRange:
      pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
      break;
    case Format420YpCbCr8BiPlanarFullRange:
      pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
      break;
  }
  NSNumber* pixelFormatNumber = [NSNumber numberWithInt:pixelFormat];
  if (pixelFormat != 0) {
    [dict setValue:pixelFormatNumber forKey:(__bridge NSString*)kCVPixelBufferPixelFormatTypeKey];
  }

  AVAssetReaderTrackOutput* output = [[AVAssetReaderTrackOutput alloc] initWithTrack:firstVideoTrack outputSettings:dict];
  output.alwaysCopiesSampleData = NO;
  [reader addOutput:output];
  [reader startReading];

  assetReader = reader;
  assetOutput = output;
  return YES;
}

- (void)generateBuffers {
  assert(lastModel);
  CMTime bufferTimeSeen = [self turnBuffersIntoFrames];
  if (!lastModel.willRequestFramesRepeatedly) {
    // If we won't be called repeatedly, then re-schedule ourself to be called
    // again just before the buffers we decoded run out. But how soon? It
    // depends on how full is our frame array.
    double fullness = 0.0;
    static const double fullnessFactor = 3.0;
    CFMutableArrayRef timestamps = nil;
    if (frameTimestamps) {
      timestamps = (__bridge CFMutableArrayRef)CFRetain(frameTimestamps);
    }
    if (timestamps) {
      fullness = (double)CFArrayGetCount(timestamps) / (double)MAX_FRAMES_TO_HOLD;
      CFRelease(timestamps);
    }

    double seconds = CMTimeGetSeconds(bufferTimeSeen) * (fullness * fullnessFactor);
    if (seconds < 0.1) {
      seconds = 0.1;
    }

    //NSLog(@"generateBuffers: rescheduling in %0.2f seconds.", seconds);

    // Schedule the block to be called in bufferTimeSeen from now.
    CFAbsoluteTime absoluteNow = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime absoluteTarget = absoluteNow + seconds;

    VideoDecoder* decoder = self;

    CFRunLoopRef runLoop = CFRunLoopGetMain();
    CFRunLoopTimerRef loopTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, absoluteTarget, 0, 0, 0, ^(CFRunLoopTimerRef timer) {
      [decoder generateBuffers];
    });
    CFRunLoopAddTimer(runLoop, loopTimer, kCFRunLoopDefaultMode);
    CFRelease(loopTimer);
  }
}

- (CMTime)turnBuffersIntoFrames {
  assert(lastModel);

  // This function is called from other threads, and has to be sensitive to
  // our asset structures being released during the call.
  @autoreleasepool {
    CMTime bufferTimeSeen = CMTimeMake(0, 1);

    AVAssetReader* reader = [[assetReader retain] autorelease];
    AVAssetReaderOutput* output = [[assetOutput retain] autorelease];
    if (!reader || !output) {
      return bufferTimeSeen;
    }

    // Capture as many sample buffers as we can.
    BOOL wantsMoreFrames = [controller wantsMoreFrames];
    while (wantsMoreFrames) {
      // Grab frames while we can, as long as our controller wants them.
      AVAssetReaderStatus status = [reader status];
      while (status == AVAssetReaderStatusReading) {
        CMSampleBufferRef buffer = [output copyNextSampleBuffer];
        if (buffer) {
          if (lastModel.canHandleBuffers) {
            wantsMoreFrames = [controller handleBuffer:buffer];
          } else {
            wantsMoreFrames = [self decompressBufferIntoFrames:buffer];
            bufferTimeSeen = CMTimeAdd(bufferTimeSeen, CMSampleBufferGetDuration(buffer));
            if (CMTimeGetSeconds(bufferTimeSeen) >= SECONDS_OF_FRAMES_TO_BUFFER) {
              //NSLog(@"turnBuffersIntoFrames exiting because we saw %f seconds of buffers.", CMTimeGetSeconds(bufferTimeSeen));
              wantsMoreFrames = NO;
            }
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
          [controller signalNoMoreBuffers];

          BOOL didReset = [self readAssetFromBeginning];
          if (!didReset) {
            return bufferTimeSeen;
          }
          // Re-establish our local asset structures.
          reader = [[assetReader retain] autorelease];
          output = [[assetOutput retain] autorelease];
          if (!reader || !output) {
            return bufferTimeSeen;
          }
          break;
        }
        case AVAssetReaderStatusFailed:
        case AVAssetReaderStatusCancelled:
        case AVAssetReaderStatusUnknown:
          // That's enough for now. Our controller can try again.
          return bufferTimeSeen;
        default:
          // The only reason we should reach this is if we are still reading and
          // our controller doesn't want any more frames.
          assert(status == AVAssetReaderStatusReading);
          assert(!wantsMoreFrames);
          break;
      };
    }
    return bufferTimeSeen;
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

  // Only attempt to decode buffers with sample data.
  CMItemCount sampleCount = CMSampleBufferGetNumSamples(buffer);
  if (sampleCount == 0) {
    return YES;
  }

  VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression | kVTDecodeFrame_EnableTemporalProcessing;
  OSStatus error = VTDecompressionSessionDecodeFrame(decompressor, buffer, flags, buffer, NULL);
  BOOL decodeSuccess = (error == noErr);
  if (!decodeSuccess) {
    NSLog(@"decompressBufferIntoFrames failed to decode buffer %@.", buffer);
  }

  // See if our frameCount is approaching our limit.
  static const CFIndex FRAME_BUFFER_GETTING_FULL = (CFIndex)(MAX_FRAMES_TO_HOLD * 0.8);
  CFIndex frameCount = CFArrayGetCount(frameTimestamps);
  return (frameCount < FRAME_BUFFER_GETTING_FULL);
}

- (void)outputImageAsFrame:(CVImageBufferRef)image {
  // See if we can get an IOSurface from the pixel buffer.
  IOSurfaceRef surface = (__bridge IOSurfaceRef)CFRetain(CVPixelBufferGetIOSurface(image));
  if (!surface) {
    return;
  }
  [controller handleFrame:surface];
  CFRelease(surface);
}

@end
