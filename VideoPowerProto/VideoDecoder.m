//
//  VideoDecoder.m
//  VideoPowerProto
//
//  Created by Brad Werth on 6/15/21.
//

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

#import "VideoDecoder.h"
#import "AutoreleasedLock.h"
#import "MainViewController.h"
#import "VideoModel.h"

@implementation VideoDecoder {
  MainViewController* controller;
  VideoModel* lastModel;
  AVAsset* asset;
  AVAssetTrack* firstVideoTrack;
  AVAssetReader* assetReader;
  AVAssetReaderTrackOutput* assetOutput;
  NSRecursiveLock* assetStructuresLock;
  VTDecompressionSessionRef decompressor;
  NSDate* timeAtStart;
  NSMutableArray* frameImages;
  NSMutableOrderedSet* frameTimestamps;
  NSRecursiveLock* frameStructuresLock;
  BOOL frameTimerActive;
  dispatch_queue_global_t frameTimerQueue;
  dispatch_source_t frameTimerSource;
  CFRunLoopRef generateRunLoop;
  CFRunLoopTimerRef generateTimer;
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
  assetStructuresLock = [[NSRecursiveLock alloc] init];
  decompressor = nil;
  timeAtStart = nil;
  frameImages = [[NSMutableArray alloc] initWithCapacity:MAX_FRAMES_TO_HOLD];
  frameTimestamps = [[NSMutableOrderedSet alloc] init];
  frameStructuresLock = [[NSRecursiveLock alloc] init];

  // Create our frame timer, and start it up in a suspended state.
  frameTimerActive = NO;
  frameTimerQueue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
  frameTimerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, frameTimerQueue);
  dispatch_source_set_timer(frameTimerSource, DISPATCH_TIME_NOW, FRAME_INTERVAL_NS, FRAME_INTERVAL_LEEWAY_NS);
  dispatch_set_context(frameTimerSource, self);
  dispatch_source_set_event_handler_f(frameTimerSource, frameTimerCallback);

  // Setup the timer and runloop we'll use to reschedule generateBuffers, if
  // needed;
  // generateRunLoop is unretained.
  generateRunLoop = CFRunLoopGetMain();
  generateTimer = nil;
  
  return self;
}

- (void)dealloc {
  // Get rid of any existing decoding.
  [self stopDecode];

  [lastModel release];
  lastModel = nil;

  [asset release];
  asset = nil;

  [assetStructuresLock release];
  assetStructuresLock = nil;

  dispatch_resume(frameTimerSource);
  dispatch_release(frameTimerSource);
  dispatch_release(frameTimerQueue);

  [frameImages release];
  frameImages = nil;

  [frameTimestamps release];
  frameTimestamps = nil;

  [frameStructuresLock release];
  frameStructuresLock = nil;

  [super dealloc];
}

- (void)stopDecode {
  [self stopDecompressor];

  assert(generateRunLoop);
  if (generateTimer) {
    CFRunLoopRemoveTimer(generateRunLoop, generateTimer, kCFRunLoopDefaultMode);
    CFRelease(generateTimer);
  }
  generateTimer = nil;

  if (frameTimerActive) {
    dispatch_suspend(frameTimerSource);
  }
  frameTimerActive = NO;

  [timeAtStart release];
  timeAtStart = nil;

  @autoreleasepool {
    [AutoreleasedLock lock:assetStructuresLock];
    [AutoreleasedLock lock:frameStructuresLock];

    if (frameImages) {
      [frameImages removeAllObjects];
    }

    if (frameTimestamps) {
      [frameTimestamps removeAllObjects];
    }

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

  @autoreleasepool {
    [AutoreleasedLock lock:assetStructuresLock];

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
}

- (void)handleTracksWithCompletionHandler:(void (^)(BOOL))block {
  assert(lastModel);
  assert(asset);

  @autoreleasepool {
    [AutoreleasedLock lock:assetStructuresLock];

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
}

- (void)handleFormatsWithCompletionHandler:(void (^)(BOOL))block {
  assert(firstVideoTrack);

  @autoreleasepool {
    [AutoreleasedLock lock:assetStructuresLock];

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

    CMFormatDescriptionRef modifiedFormat = NULL;
    CFDictionaryRef outputProps = NULL;

    /*
    // Make a new format based on the old format, that changes some extensions.
    // This doesn't work.
    FourCharCode codec = CMFormatDescriptionGetMediaSubType(format);
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format);
    CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(format);

    CFMutableDictionaryRef modifiedExtensions = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, extensions);

    // Force the ITU color primaries
    CFDictionarySetValue(modifiedExtensions, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020);

    // Force the HLG transfer function.
    CFDictionarySetValue(modifiedExtensions, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG);

    CMVideoFormatDescriptionCreate(kCFAllocatorDefault, codec, dimensions.width, dimensions.height, modifiedExtensions, &modifiedFormat);

    if (modifiedExtensions) {
      CFRelease(modifiedExtensions);
    }
    */

    //NSLog(@"Old format was %@ and new format is %@.", format, modifiedFormat);

    static const long OUTPUT_KEY_VALUE_MAX = 5;
    const void* outputKeys[OUTPUT_KEY_VALUE_MAX];
    const void* outputValues[OUTPUT_KEY_VALUE_MAX];
    long keyValueCount = 0;

    CFNumberRef pixelFormatTypeNumber = NULL;
    CFDictionaryRef ioSurfaceProps = NULL;

    // Ensure the video is decoded with 10-bit color.
    SInt32 pixelFormatTypeValue = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    pixelFormatTypeNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pixelFormatTypeValue);
    outputKeys[keyValueCount] = kCVPixelBufferPixelFormatTypeKey;
    outputValues[keyValueCount] = pixelFormatTypeNumber;
    keyValueCount++;

    /*
    // Explictly set the color space.
    // This doesn't work.
    const void* ioSurfaceKeys[] = {CFSTR("IOSurfaceColorSpace")};
    const void* ioSurfaceValues[] = {kCGColorSpaceITUR_2100_HLG};
    ioSurfaceProps = CFDictionaryCreate(kCFAllocatorDefault, ioSurfaceKeys, ioSurfaceValues, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    outputKeys[keyValueCount] = kCVPixelBufferIOSurfacePropertiesKey;
    outputValues[keyValueCount] = ioSurfaceProps;
    keyValueCount++;
    */

    // Actually create the outputProps.
    outputProps = CFDictionaryCreate(kCFAllocatorDefault, outputKeys, outputValues, keyValueCount, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    // Release any memory we might have created earlier.
    if (pixelFormatTypeNumber) {
      CFRelease(pixelFormatTypeNumber);
    }
    if (ioSurfaceProps) {
      CFRelease(ioSurfaceProps);
    }
    
    // If we modified the format, switch to it.
    if (modifiedFormat) {
      format = modifiedFormat;
    }

    VTDecompressionOutputCallbackRecord callback = {DecompressorCallback, self};
    OSStatus error = VTDecompressionSessionCreate(kCFAllocatorDefault, format, NULL, outputProps, &callback, &decompressor);

    // Release the memory we needed to set up the decompressor.
    if (modifiedFormat) {
      CFRelease(modifiedFormat);
    }
    if (outputProps) {
      CFRelease(outputProps);
    }

    if (!decompressor) {
      NSLog(@"Failed to create decompression session with error %d.", error);
      block(NO);
      return;
    }
    assert(error == noErr);

    /*
    // See which properties can be modified in the session.
    CFDictionaryRef sessionProps = nil;
    error = VTSessionCopySupportedPropertyDictionary(decompressor, &sessionProps);
    NSLog(@"Decompressor props are %@.\n", sessionProps);
    CFRelease(sessionProps);
    */

    /*
    // Force a color conversion to HLG.
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_HLG);
    CFDataRef iccProfile = CGColorSpaceCopyICCData(colorSpace);
    const void* pixelTransferKeys[] = {kVTPixelTransferPropertyKey_DestinationICCProfile};
    const void* pixelTransferValues[] = {iccProfile};
    CFDictionaryRef pixelTransferProps = CFDictionaryCreate(kCFAllocatorDefault, pixelTransferKeys, pixelTransferValues, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void* pixelTransferKeys[] = {kVTPixelTransferPropertyKey_DestinationColorPrimaries, kVTPixelTransferPropertyKey_DestinationTransferFunction};
    const void* pixelTransferValues[] = {kCMFormatDescriptionColorPrimaries_ITU_R_2020, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG};
    CFDictionaryRef pixelTransferProps = CFDictionaryCreate(kCFAllocatorDefault, pixelTransferKeys, pixelTransferValues, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    error = VTSessionSetProperty(decompressor, kVTDecompressionPropertyKey_PixelTransferProperties, pixelTransferProps);
    assert(error == noErr);
    CFRelease(colorSpace);
    CFRelease(iccProfile);
    CFRelease(pixelTransferProps);
    */

    /*
    error = VTSessionSetProperty(
        decompressor,
        kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata,
        kCFBooleanTrue);
    CFBooleanRef isUsingHDR = nil;
    error = VTSessionCopyProperty(
        decompressor,
        kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata,
        kCFAllocatorDefault,
        &isUsingHDR);
    NSLog(@"Is Using HDR? %@.", isUsingHDR);
    if (isUsingHDR) {
      CFRelease(isUsingHDR);
    }
    */
  }

  CFRetain(decompressor);

  frameTimerActive = YES;
  dispatch_resume(frameTimerSource);

  block(YES);
}

// Define a C-style callback for our decompressor.
void DecompressorCallback(void *decompressionOutputRefCon, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef image, CMTime presentationTimestamp, CMTime presentationDuration) {
  //NSLog(@"DecompressorCallback.");
  VideoDecoder* decoder = (VideoDecoder*)decompressionOutputRefCon;
  [decoder storeImage:image withTimestamp:presentationTimestamp];
}

- (void)storeImage:(CVImageBufferRef)image withTimestamp:(CMTime)ts {
  Float64 seconds = CMTimeGetSeconds(ts);
  NSDate* playbackDate = [NSDate dateWithTimeInterval:seconds sinceDate:timeAtStart];

  // There is no guarantee that this frame is arriving in order. We need to
  // figure out where to insert this frame, relative to the other frames we're
  // already holding.
  @autoreleasepool {
    [AutoreleasedLock lock:frameStructuresLock];

    NSRange wholeRange = NSMakeRange(0, [frameTimestamps count]);
    NSUInteger index = [frameTimestamps indexOfObject:playbackDate inSortedRange:wholeRange options:NSBinarySearchingInsertionIndex usingComparator:^NSComparisonResult(NSDate* date1, NSDate* date2) {
      return [date1 compare:date2];
    }];

    //NSLog(@"storeImage playbackTime %f stored at index %lu.", playbackTime, index);

    // Insert the image and the date at the index.
    [frameImages insertObject:(__bridge id)image atIndex:index];
    [frameTimestamps insertObject:playbackDate atIndex:index];
  }
}

void frameTimerCallback(void* context) {
  VideoDecoder* decoder = (VideoDecoder*)context;
  [decoder processFrameImages];
}

- (void)processFrameImages {
  assert(frameTimerActive);

  @autoreleasepool {
    [AutoreleasedLock lock:frameStructuresLock];

    NSUInteger frameCount = [frameTimestamps count];

    // If we're holding too many frames, get rid of the most recent ones.
    if (frameCount > MAX_FRAMES_TO_HOLD) {
      // Dump newest frames to bring us back down to the maximum. We do it this
      // way to ensure that the older frames will eventually get output. If we
      // dumped older frames, we run the risk of never catching up to the
      // timestamp of the oldest frames in the queue.
      NSRange staleFrames = NSMakeRange(MAX_FRAMES_TO_HOLD, frameCount - MAX_FRAMES_TO_HOLD);
      [frameImages removeObjectsInRange:staleFrames];
      [frameTimestamps removeObjectsInRange:staleFrames];
      frameCount = MAX_FRAMES_TO_HOLD;
    }

    // Loop through all the frames we're holding and output the latest one that
    // has a timestamp before now (if any).
    NSDate* now = [NSDate date];
    //NSLog(@"processFrameImages now is %f.", [now timeIntervalSinceReferenceDate]);

    NSUInteger f = 0;
    while (f < frameCount) {
      NSDate* ts = [frameTimestamps objectAtIndex:f];
      if ([now compare:ts] == NSOrderedAscending) {
        // It's not time for this frame yet.
        break;
      }
      f++;
    }

    //NSLog(@"processFrameImages f is %ld and frameCount is %ld.", f, frameCount);

    // The previous frame we saw is the latest one that we can output.
    if (f > 0) {
      NSUInteger latestFrameIndex = f - 1;
      CVImageBufferRef image = (CVImageBufferRef)[frameImages objectAtIndex:latestFrameIndex];
      [self outputImageAsFrame:image];

      // Get rid of all frames up to and including the one we just output.
      NSRange staleFrames = NSMakeRange(0, latestFrameIndex);
      [frameImages removeObjectsInRange:staleFrames];
      [frameTimestamps removeObjectsInRange:staleFrames];
    }
  }
}

- (BOOL)readAssetFromBeginning {
  assert(lastModel);
  assert(firstVideoTrack);

  @autoreleasepool {
    [AutoreleasedLock lock:assetStructuresLock];
    [AutoreleasedLock lock:frameStructuresLock];

    if (!lastModel.canHandleBuffers) {
      // Reset our timeAtStart to the latest of either right now, or the latest
      // timestamp frame we're holding.
      NSDate* now = [NSDate date];
      NSDate* latestFrameTimestamp = [frameTimestamps lastObject];
      if (latestFrameTimestamp) {
        timeAtStart = [[now laterDate:latestFrameTimestamp] retain];
      } else {
        timeAtStart = [now retain];
      }
    }

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

    NSDictionary<NSString*, id>* dict = nil;

    if (lastModel.canHandleBuffers) {
      dict = [NSMutableDictionary<NSString*, id> dictionary];

      // Always specify IOSurface key. Using a blank dictionary lets the OS decide
      // the best way to allocate IOSurfaces.
      [dict setValue:[NSDictionary dictionary] forKey:(__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey];

      // Specify that we can accept wide color.
      //[dict setValue:@YES forKey:AVVideoAllowWideColorKey];
    }

    assetOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:firstVideoTrack outputSettings:dict];
    assetOutput.alwaysCopiesSampleData = NO;
    [assetReader addOutput:assetOutput];
    [assetReader startReading];
  }

  return YES;
}

- (void)generateBuffers {
  //NSLog(@"generateBuffers.");
  assert(lastModel);
  CMTime bufferTimeSeen = [self turnBuffersIntoFrames];
  if (!lastModel.willRequestFramesRepeatedly) {
    // If we won't be called repeatedly, then re-schedule ourself to be called
    // again just before the buffers we decoded run out. But how soon? It
    // depends on how full is our frame array.
    NSUInteger frameCount = [frameTimestamps count];
    double fullness = (double)frameCount / (double)MAX_FRAMES_TO_HOLD;

    static const double fullnessFactor = 3.0;
    double seconds = CMTimeGetSeconds(bufferTimeSeen) * (fullness * fullnessFactor);
    if (seconds < 0.1) {
      seconds = 0.1;
    }

    //NSLog(@"generateBuffers: rescheduling in %0.2f seconds.", seconds);

    // Schedule the block to be called in bufferTimeSeen from now.
    CFAbsoluteTime absoluteNow = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime absoluteTarget = absoluteNow + seconds;

    // Tick our generateTimer to run again, at absoluteTarget.
    VideoDecoder* decoder = self;
    generateTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, absoluteTarget, 0, 0, 0, ^(CFRunLoopTimerRef timer) {
      [decoder generateBuffers];
    });
    CFRunLoopAddTimer(generateRunLoop, generateTimer, kCFRunLoopDefaultMode);
  }
}

- (CMTime)turnBuffersIntoFrames {
  assert(lastModel);
  CMTime bufferTimeSeen = CMTimeMake(0, 1);

  @autoreleasepool {
    [AutoreleasedLock lock:assetStructuresLock];

    if (!assetReader || !assetOutput) {
      return bufferTimeSeen;
    }

    // Capture as many sample buffers as we can.
    BOOL wantsMoreFrames = [controller wantsMoreFrames];
    while (wantsMoreFrames) {
      // Grab frames while we can, as long as our controller wants them.
      AVAssetReaderStatus status = [assetReader status];
      while (status == AVAssetReaderStatusReading) {
        CMSampleBufferRef buffer = [assetOutput copyNextSampleBuffer];
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
        status = [assetReader status];

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
          if (!assetReader || !assetOutput) {
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
  }
  return bufferTimeSeen;
}

- (void)stopDecompressor {
  if (decompressor) {
    VTDecompressionSessionWaitForAsynchronousFrames(decompressor);
    VTDecompressionSessionInvalidate(decompressor);
    CFRelease(decompressor);
    decompressor = nil;
  }
}

- (BOOL)decompressBufferIntoFrames:(CMSampleBufferRef)buffer {
  //NSLog(@"decompressBufferIntoFrames.");

  if (!decompressor) {
    return NO;
  }

  // Only attempt to decode buffers with sample data.
  CMItemCount sampleCount = CMSampleBufferGetNumSamples(buffer);
  if (sampleCount == 0) {
    return YES;
  }

  VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression | kVTDecodeFrame_EnableTemporalProcessing;
  
  OSStatus error = VTDecompressionSessionDecodeFrame(decompressor, buffer, flags, buffer, NULL);
  BOOL decodeSuccess = (error == noErr);
  if (!decodeSuccess) {
    NSLog(@"decompressBufferIntoFrames failed to decode buffer %@ with error %@.", buffer, [VideoDecoder decodeErrorToString:error]);
  }

  // See if our frameCount is approaching our limit.
  static const CFIndex FRAME_BUFFER_GETTING_FULL = (CFIndex)(MAX_FRAMES_TO_HOLD * 0.8);
  NSUInteger frameCount = [frameTimestamps count];
  return (frameCount < FRAME_BUFFER_GETTING_FULL);
}

- (void)outputImageAsFrame:(CVImageBufferRef)image {
  //NSLog(@"outputImageAsFrame.");

  // See if we can get an IOSurface from the pixel buffer.
  IOSurfaceRef surface = CVPixelBufferGetIOSurface(image);
  if (!surface) {
    return;
  }
  [controller handleFrame:surface];
}

+ (NSString*)decodeErrorToString:(OSStatus)error {
  switch (error) {
    case kVTFormatDescriptionChangeNotSupportedErr:
      return @"kVTFormatDescriptionChangeNotSupportedErr";
    case kVTVideoDecoderAuthorizationErr:
      return @"kVTVideoDecoderAuthorizationErr";
    case kVTVideoDecoderBadDataErr:
      return @"kVTVideoDecoderBadDataErr";
    case kVTVideoDecoderMalfunctionErr:
      return @"kVTVideoDecoderMalfunctionErr";
    case kVTVideoDecoderNotAvailableNowErr:
      return @"kVTVideoDecoderNotAvailableNowErr";
    case kVTVideoDecoderUnsupportedDataFormatErr:
      return @"kVTVideoDecoderUnsupportedDataFormatErr";
    case kVTVideoEncoderAuthorizationErr:
      return @"kVTVideoEncoderAuthorizationErr";
    /*
    case kVTVideoDecoderNeedsRosettaErr:
      return @"kVTVideoDecoderNeedsRosettaErr";
    */
    case kVTVideoDecoderRemovedErr:
      return @"kVTVideoDecoderRemovedErr";
  }
  return [NSString stringWithFormat:@"%d", error];
}

@end
