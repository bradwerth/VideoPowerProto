//
//  ColoredBackgroundView.h
//  VideoPowerProto
//
//  Created by Brad Werth on 7/30/21.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface ColoredBackgroundView : NSView
@property (nonatomic, copy) IBInspectable NSColor* color;
@end

NS_ASSUME_NONNULL_END
