//
//  ColoredBackgroundView.m
//  VideoPowerProto
//
//  Created by Brad Werth on 7/30/21.
//

#import "ColoredBackgroundView.h"

@implementation ColoredBackgroundView

- (instancetype)initWithFrame:(NSRect)frameRect {
  // If not instantiated from a xib -- why? -- assign default values.
  self = [super initWithFrame:frameRect];
  self.color = [NSColor clearColor];
  return self;
}

- (void)dealloc {
  [_color release];
  [super dealloc];
}

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
  [self.color drawSwatchInRect:dirtyRect];
}

@end
