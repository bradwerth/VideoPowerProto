//
//  VideoModel.m
//  video-low-power
//
//  Created by Brad Werth on 6/10/21.
//

#import "VideoModel.h"

@implementation VideoModel
// Everything of interest is managed by our properties.

- (nonnull id)copyWithZone:(nullable NSZone*)zone {
  VideoModel* model = [[VideoModel alloc] init];
  model.videoFile = self.videoFile;
  model.layerClass = self.layerClass;
  model.buffering = self.buffering;
  model.flashingOverlay = self.flashingOverlay;
  return model;
}

- (AVAsset*) videoAsset {
  NSString* resource = [[self videoFile] stringByDeletingPathExtension];
  NSString* extension = [[self videoFile] pathExtension];
  NSBundle* bundle = [NSBundle mainBundle];
  NSURL* url = [bundle URLForResource:resource withExtension:extension subdirectory:@"Media"];
  return [AVAsset assetWithURL:url];
}

- (BOOL) canHandleBuffers {
  return (self.layerClass == LayerClassAVSampleBufferDisplayLayer) && (self.buffering == BufferingDirect);
}

- (BOOL) willRequestFramesRepeatedly {
  return (self.layerClass == LayerClassAVSampleBufferDisplayLayer) && (self.buffering == BufferingDirect);
}

- (void) waitForVideoAssetFirstTrack: (void (^)(AVAssetTrack*))handler {
  AVAsset* asset = [self videoAsset];
  if (!asset) {
    // No tracks, so call the handler immediately.
    handler(nil);
    return;
  }

  [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
    NSError* error = nil;
    AVKeyValueStatus status = [asset statusOfValueForKey:@"tracks" error:&error];
    if (status == AVKeyValueStatusFailed) {
      NSLog(@"Track loading failed with: %@.", error);
      handler(nil);
      return;
    }

    // Track property is loaded, so we can get the video tracks without blocking.
    AVAssetTrack* firstTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!firstTrack) {
      NSLog(@"No video track.");
      handler(nil);
      return;
    }

    // Call the handler with the first track.
    handler(firstTrack);
  }];
}
@end
