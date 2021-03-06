//
//  VideoModel.h
//  video-low-power
//
//  Created by Brad Werth on 6/10/21.
//

#import <AVKit/AVKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Keep these values synced with the Tags used in the xib.
typedef NS_ENUM(NSInteger, LayerClass) {
  LayerClassAVSampleBufferDisplayLayer,
  LayerClassCALayer,
};

// Keep these values synced with the Tags used in the xib.
typedef NS_ENUM(NSInteger, Buffering) {
  BufferingDirect,
  BufferingRecreated,
};

@interface VideoModel : NSObject <NSCopying>

// These properties should be copied in the implementation of copyWithZone.
@property (copy) NSString* videoFile;
@property LayerClass layerClass;
@property Buffering buffering;
@property BOOL flashingOverlay;

- (nonnull id)copyWithZone:(nullable NSZone*)zone;

// Provide a convenience property for turning the videoFilename into an
// AVAsset.
@property (nonatomic, readonly) AVAsset* videoAsset;

@property (nonatomic, readonly) BOOL canHandleBuffers;
@property (nonatomic, readonly) BOOL willRequestFramesRepeatedly;

- (void) waitForVideoAssetFirstTrack: (void (^)(AVAssetTrack*))handler;

@end

NS_ASSUME_NONNULL_END
