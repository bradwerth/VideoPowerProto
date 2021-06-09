//
//  VideoModel.h
//  video-low-power
//
//  Created by Brad Werth on 6/10/21.
//

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
typedef NS_OPTIONS(NSInteger, PixelBuffer) {
  OpenGL = 1 << 0,
  IOSurfaceCoreAnimation = 1 << 1,
};

@interface VideoModel : NSObject

@property LayerClass layerClass;
@property Buffering buffering;
@property PixelBuffer pixelBuffer;

@end

NS_ASSUME_NONNULL_END
