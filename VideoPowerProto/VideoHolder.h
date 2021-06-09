//
//  VideoHolder.h
//  video-low-power
//
//  Created by Brad Werth on 6/10/21.
//

#import <Cocoa/Cocoa.h>

@class VideoModel;

NS_ASSUME_NONNULL_BEGIN

@interface VideoHolder : NSView
- (void)resetWithModel:(VideoModel*)model;
@end

NS_ASSUME_NONNULL_END
