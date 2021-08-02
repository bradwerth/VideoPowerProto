//
//  VideoDecoder.h
//  VideoPowerProto
//
//  Created by Brad Werth on 6/15/21.
//

#import <Foundation/Foundation.h>

@class MainViewController;
@class VideoModel;

NS_ASSUME_NONNULL_BEGIN

@interface VideoDecoder : NSObject
- (instancetype)initWithController:(MainViewController*)inController;
- (void)resetWithModel:(nullable VideoModel*)model completionHandler:(void (^)(BOOL))block;
- (void)generateBuffers;
@end

NS_ASSUME_NONNULL_END
