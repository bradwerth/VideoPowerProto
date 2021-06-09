//
//  MainViewController.h
//  video-low-power
//
//  Created by Brad Werth on 6/10/21.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface MainViewController : NSViewController

- (IBAction)selectLayerClass:(id)sender;
- (IBAction)selectBuffering:(id)sender;
- (IBAction)clickPixelBufferButton:(id)sender;

@end

NS_ASSUME_NONNULL_END
