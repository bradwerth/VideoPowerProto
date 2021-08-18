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

@property (strong) IBOutlet NSPopUpButton* layerClassPopUp;
@property (strong) IBOutlet NSPopUpButton* bufferingPopUp;
@property (strong) IBOutlet NSPopUpButton* formatPopUp;
@property (strong) IBOutlet NSButton* pixelBufferOpenGLCompatibilityButton;
@property (strong) IBOutlet NSButton* pixelBufferIOSurfaceCoreAnimationCompatibilityButton;

@property (strong) IBOutlet VideoHolder* videoHolder;
@end

@implementation MainViewController {
  NSColor* oldWindowColor;
  NSRect oldContentViewFrame;
  NSArray* oldSubviews;
  VideoDecoder* videoDecoder;
}

- (void)viewDidLoad {
  [super viewDidLoad];

  oldWindowColor = nil;
  oldSubviews = nil;
  videoDecoder = [[VideoDecoder alloc] initWithController:self];

  // Listen to all the properties that might change in our model.
  [self.videoModel addObserver:self forKeyPath:@"layerClass" options:0 context:nil];
  [self.videoModel addObserver:self forKeyPath:@"buffering" options:0 context:nil];
  [self.videoModel addObserver:self forKeyPath:@"format" options:0 context:nil];
  [self.videoModel addObserver:self forKeyPath:@"pixelBuffer" options:0 context:nil];
  [self.videoModel addObserver:self forKeyPath:@"videoFilename" options:0 context:nil];

  // Setup our initial video.
  [self clearVideo];
}

- (void)dealloc {
  [_layerClassPopUp release];
  [_bufferingPopUp release];
  [_formatPopUp release];
  [_pixelBufferOpenGLCompatibilityButton release];
  [_pixelBufferIOSurfaceCoreAnimationCompatibilityButton release];
  [_videoHolder release];

  [oldWindowColor release];
  [oldSubviews release];
  [videoDecoder release];
  [self.videoModel removeObserver:self forKeyPath:@"layerClass"];
  [self.videoModel removeObserver:self forKeyPath:@"buffering"];
  [self.videoModel removeObserver:self forKeyPath:@"format"];
  [self.videoModel removeObserver:self forKeyPath:@"pixelBuffer"];
  [self.videoModel removeObserver:self forKeyPath:@"videoFilename"];
  [super dealloc];
}

- (IBAction)selectLayerClass:(NSPopUpButton*)sender {
  self.videoModel.layerClass = sender.selectedTag;
}

- (IBAction)selectBuffering:(NSPopUpButton*)sender {
  self.videoModel.buffering = sender.selectedTag;
}

- (IBAction)selectFormat:(NSPopUpButton*)sender {
  self.videoModel.format = sender.selectedTag;
}

- (IBAction)clickPixelBufferButton:(NSButton*)sender {
  bool isOn = (sender.state == NSControlStateValueOn);
  PixelBuffer oldValue = [self videoModel].pixelBuffer;
  self.videoModel.pixelBuffer = (isOn ? (oldValue | sender.tag) : (oldValue & ~sender.tag));
}

- (IBAction)clickFullscreenButton:(NSButton*)sender {
  [self.view.window toggleFullScreen:sender];
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context {
  // All changes to the model require resetting the videoDecoder first, and
  // when that is complete, resetting the videoHolder. We accomplish that by
  // passing a completion block to the decoder.
  [self clearVideo];
  [self resetVideo];
}

- (void)clearVideo {
  [self.videoHolder resetWithModel:nil];
  [videoDecoder resetWithModel:nil completionHandler:^(BOOL _ignored){}];
}

- (void)resetVideo {
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
  CALayer* layer = [self.videoHolder detachContentLayer];

  NSWindow* window = self.view.window;
  oldContentViewFrame = window.contentView.frame;

  oldSubviews = [window.contentView.subviews copy];
  window.contentView.subviews = [NSArray array];
  window.contentView.wantsLayer = YES;
  [window.contentView setLayer:layer];

  oldWindowColor = [window.backgroundColor retain];
  window.backgroundColor = [NSColor blackColor];

  [NSCursor hide];
}

- (void)windowWillExitFullScreen:(NSNotification *)notification {
  NSWindow* window = self.view.window;

  window.backgroundColor = oldWindowColor;
  [oldWindowColor release];
  oldWindowColor = nil;

  window.contentView.frame = oldContentViewFrame;

  window.contentView.wantsLayer = NO;
  [window.contentView setLayer:nil];

  window.contentView.subviews = oldSubviews;
  [oldSubviews release];
  oldSubviews = nil;

  window.contentView.frame = oldContentViewFrame;

  [self.videoHolder reattachContentLayer];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
  [NSCursor unhide];
}
@end
