//
//  MainViewController.m
//  video-low-power
//
//  Created by Brad Werth on 6/10/21.
//

#import <AVFoundation/AVFoundation.h>

#import "MainViewController.h"
#import "VideoDecoder.h"
#import "VideoHolder.h"
#import "VideoModel.h"

@interface MainViewController ()

@property (strong) IBOutlet VideoModel* videoModel;
@property (strong) IBOutlet VideoHolder* videoHolder;

@property (strong) IBOutlet NSPopUpButton* videoFilePopUp;
@property (strong) IBOutlet NSPopUpButton* layerClassPopUp;
@property (strong) IBOutlet NSPopUpButton* bufferingPopUp;

@end

@implementation MainViewController {
  NSRect oldContentViewFrame;
  CALayer* backgroundLayer;
  CALayer* videoLayer;
  CALayer* overlayLayer;
  NSArray* oldSubviews;
  VideoDecoder* videoDecoder;
}

- (void)viewDidLoad {
  [super viewDidLoad];

  backgroundLayer = nil;
  videoLayer = nil;
  overlayLayer = nil;
  oldSubviews = nil;
  videoDecoder = [[VideoDecoder alloc] initWithController:self];

  NSWindow* window = self.view.window;
  window.contentView.wantsLayer = YES;

  // Listen to all the properties that might change in our model.
  [self.videoModel addObserver:self forKeyPath:@"videoFile" options:0 context:nil];
  [self.videoModel addObserver:self forKeyPath:@"layerClass" options:0 context:nil];
  [self.videoModel addObserver:self forKeyPath:@"buffering" options:0 context:nil];
  [self.videoModel addObserver:self forKeyPath:@"flashingOverlay" options:0 context:nil];

  [self clearVideo];

  // Populate the video file menu, which will setup our initial video.
  [self populateVideoFileMenu];
}

- (void)dealloc {
  [_videoFilePopUp release];
  [_layerClassPopUp release];
  [_bufferingPopUp release];
  [_videoHolder release];

  [backgroundLayer release];
  [videoLayer release];
  [overlayLayer release];
  [oldSubviews release];
  [videoDecoder release];

  [self.videoModel removeObserver:self forKeyPath:@"videoFile"];
  [self.videoModel removeObserver:self forKeyPath:@"layerClass"];
  [self.videoModel removeObserver:self forKeyPath:@"buffering"];
  [self.videoModel removeObserver:self forKeyPath:@"flashingOverlay"];
  [_videoModel release];

  [super dealloc];
}

- (IBAction)selectVideoFile:(NSPopUpButton*)sender {
  self.videoModel.videoFile = sender.titleOfSelectedItem;
}

- (IBAction)selectLayerClass:(NSPopUpButton*)sender {
  self.videoModel.layerClass = sender.selectedTag;
}

- (IBAction)selectBuffering:(NSPopUpButton*)sender {
  self.videoModel.buffering = sender.selectedTag;
}

- (IBAction)clickFullscreenButton:(NSButton*)sender {
  [self.view.window toggleFullScreen:sender];
}

- (IBAction)clickFlashingOverlayButton:(NSButton*)sender {
  self.videoModel.flashingOverlay = (sender.state == NSControlStateValueOn);
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context {
  [self resetVideo];
}

- (void)populateVideoFileMenu {
  [self.videoFilePopUp removeAllItems];

  NSBundle* bundle = [NSBundle mainBundle];
  NSArray* urls = [bundle URLsForResourcesWithExtension:nil subdirectory:@"Media"];
  for (NSURL* url in urls) {
    [self.videoFilePopUp addItemWithTitle:url.lastPathComponent];
  }

  [self.videoFilePopUp selectItemAtIndex:0];
  [self selectVideoFile:self.videoFilePopUp];
}

- (void)clearVideo {
  [self.videoHolder resetWithModel:nil];
  [videoDecoder resetWithModel:nil completionHandler:^(BOOL _ignored){}];
}

- (void)resetVideo {
  // All changes to the model require resetting the videoDecoder first, and
  // when that is complete, resetting the videoHolder. We accomplish that by
  // passing a completion block to the decoder.
  MainViewController* controller = self;
  [videoDecoder resetWithModel:self.videoModel completionHandler:^(BOOL success) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (success) {
        [controller.videoHolder resetWithModel:self.videoModel];
      } else {
        [controller.videoHolder resetWithModel:nil];
      }
    });
  }];
}

- (BOOL)wantsMoreFrames {
  return [self.videoHolder wantsMoreFrames];
}

- (BOOL)handleBuffer:(CMSampleBufferRef)buffer {
  assert([self.videoModel canHandleBuffers]);
  return [self.videoHolder handleBuffer:buffer];
}

- (BOOL)handleFrame:(IOSurfaceRef)surface {
  return [self.videoHolder handleFrame:surface];
}

- (void)requestFrames {
  [videoDecoder generateBuffers];
}

- (void)signalNoMoreBuffers {
  [self.videoHolder noMoreBuffers];
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification {
  NSWindow* window = notification.object;
  oldContentViewFrame = window.contentView.frame;

  oldSubviews = [window.contentView.subviews copy];
  window.contentView.subviews = @[];

  // Lazily create the background layer.
  if (!backgroundLayer) {
    backgroundLayer = [CALayer layer];
    backgroundLayer.backgroundColor = [[NSColor blackColor] CGColor];
    backgroundLayer.position = NSZeroPoint;
    backgroundLayer.anchorPoint = NSZeroPoint;
    [window.contentView.layer addSublayer:backgroundLayer];
  }

  backgroundLayer.hidden = NO;

  videoLayer = [[self.videoHolder detachVideoLayer] retain];
  if (videoLayer) {
    [window.contentView.layer addSublayer:videoLayer];
  }

  overlayLayer = [[self.videoHolder detachOverlayLayer] retain];
  if (overlayLayer) {
    [window.contentView.layer addSublayer:overlayLayer];
  }

  // The correct size will be set in windowDidResize, which is called after windowWillEnterFullScreen.

  [NSCursor hide];
}

- (void)windowDidResize:(NSNotification *)notification {
  NSWindow* window = notification.object;
  if (window.styleMask & NSWindowStyleMaskFullScreen) {
    // Make sure the black backdrop layer and the video layer are resized
    // to fit the fullscreen size.
    if (backgroundLayer) {
      backgroundLayer.bounds = window.contentView.bounds;
    }

    if (videoLayer) {
      videoLayer.bounds = window.contentView.bounds;
    }
  }
}

- (void)windowWillExitFullScreen:(NSNotification *)notification {
  NSWindow* window = self.view.window;

  backgroundLayer.hidden = YES;

  if (videoLayer) {
    [videoLayer removeFromSuperlayer];
  }
  [self.videoHolder reattachVideoLayer];
  [videoLayer release];
  videoLayer = nil;

  if (overlayLayer) {
    [overlayLayer removeFromSuperlayer];
  }
  [self.videoHolder reattachOverlayLayer];
  [overlayLayer release];
  overlayLayer = nil;

  window.contentView.frame = oldContentViewFrame;

  window.contentView.subviews = oldSubviews;
  [oldSubviews release];
  oldSubviews = nil;
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
  [NSCursor unhide];
}
@end
