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
  NSRect oldContentViewFrame;
  NSArray* oldSubviews;
  VideoDecoder* videoDecoder;
}

- (void)viewDidLoad {
  [super viewDidLoad];

  oldSubviews = nil;
  videoDecoder = [[VideoDecoder alloc] initWithController:self];

  self.view.window.contentView.wantsLayer = YES;

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
  NSWindow* window = notification.object;
  oldContentViewFrame = window.contentView.frame;

  oldSubviews = [window.contentView.subviews copy];
  window.contentView.subviews = [NSArray array];

  CALayer* backgroundLayer = [CALayer layer];
  backgroundLayer.position = NSZeroPoint;
  backgroundLayer.anchorPoint = NSZeroPoint;
  backgroundLayer.bounds = window.contentView.bounds;
  backgroundLayer.backgroundColor = [[NSColor blackColor] CGColor];
  [window.contentView.layer addSublayer:backgroundLayer];

  CALayer* videoLayer = [self.videoHolder detachContentLayer];
  [window.contentView.layer addSublayer:videoLayer];
  videoLayer.position = NSZeroPoint;
  videoLayer.anchorPoint = NSZeroPoint;
  // The correct size will be set in windowDidResize, which is called after windowWillEnterFullScreen.

  [NSCursor hide];
}

- (void)windowDidResize:(NSNotification *)notification {
  NSWindow* window = notification.object;
  if (window.styleMask & NSWindowStyleMaskFullScreen) {
    // Make sure the black backdrop layer and the video layer are resized
    // to fit the fullscreen size.
    for (CALayer* sublayer in window.contentView.layer.sublayers) {
      sublayer.bounds = window.contentView.bounds;
    }
  }
}

- (void)windowWillExitFullScreen:(NSNotification *)notification {
  NSWindow* window = self.view.window;

  window.contentView.layer.sublayers = @[];
  [self.videoHolder reattachContentLayer];

  window.contentView.frame = oldContentViewFrame;

  window.contentView.subviews = oldSubviews;
  [oldSubviews release];
  oldSubviews = nil;
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
  [NSCursor unhide];
}
@end
