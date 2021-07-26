//
//  VideoHolder.h
//  video-low-power
//
//  Created by Brad Werth on 6/10/21.
//

#import <Cocoa/Cocoa.h>

@class VideoModel;
@class MainViewController;

NS_ASSUME_NONNULL_BEGIN

@interface VideoHolder : NSView
@property (weak) IBOutlet MainViewController* controller;

- (void)resetWithModel:(VideoModel* _Nullable)model;
- (BOOL)wantsMoreFrames;
- (BOOL)handleDecodedFrame:(CMSampleBufferRef)buffer;
@end

NS_ASSUME_NONNULL_END
