//
//  AppDelegate.m
//  video-low-power
//
//  Created by Brad Werth on 6/8/21.
//

#import "AppDelegate.h"

@interface AppDelegate ()

@property (strong) IBOutlet NSWindow *window;
@end

@implementation AppDelegate

- (void) dealloc {
  [_window release];
  [super dealloc];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
  if (self.window.contentView.inFullScreenMode) {
    [NSCursor hide];
  }
}

- (void)applicationWillResignActive:(NSNotification *)notification {
  if (self.window.contentView.inFullScreenMode) {
    [NSCursor unhide];
  }
}

@end
