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
  LayerClassCALayer,
  LayerClassAVSampleBufferDisplayLayer,
};

// Keep these values synced with the Tags used in the xib.
typedef NS_ENUM(NSInteger, Buffering) {
  BufferingDirect,
  BufferingRecreated,
};

// Keep these values synced with the Tags used in the xib.
typedef NS_ENUM(NSInteger, Format) {
  FormatUnspecified,
  Format422YpCbCr8,
  Format420YpCbCr8BiPlanarVideoRange,
  Format420YpCbCr8BiPlanarFullRange,
};

// Keep these values synced with the Tags used in the xib.
typedef NS_OPTIONS(NSInteger, PixelBuffer) {
  OpenGL = 1 << 0,
  IOSurfaceCoreAnimation = 1 << 1,
};

@interface VideoModel : NSObject <NSCopying>

// These properties should be copied in the implementation of copyWithZone.
@property LayerClass layerClass;
@property Buffering buffering;
@property Format format;
@property PixelBuffer pixelBuffer;

- (nonnull id)copyWithZone:(nullable NSZone*)zone;

// For now, we're going to hardcode this property so we make a custom getter.
// We set it as readonly so we don't forget and try to overwrite while we still
// have the custom getter.
@property (nonatomic, readonly) NSString* videoFilename;

// Provide a convenience property for turning the videoFilename into an
// AVAsset.
@property (nonatomic, readonly) AVAsset* videoAsset;

@property (nonatomic, readonly) BOOL canHandleBuffers;
@property (nonatomic, readonly) BOOL willRequestFramesRepeatedly;

- (void) waitForVideoAssetFirstTrack: (void (^)(AVAssetTrack*))handler;

@end

NS_ASSUME_NONNULL_END
