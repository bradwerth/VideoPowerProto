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
@property (strong) IBOutlet NSButton* pixelBufferOpenGLCompatibilityButton;
@property (strong) IBOutlet NSButton* pixelBufferIOSurfaceCoreAnimationCompatibilityButton;

@property (strong) IBOutlet VideoHolder* videoHolder;
@end

@implementation MainViewController {
  NSWindow* oldWindow;
  NSView* oldContentView;
  NSView* oldVideoHolderSuperview;
  NSRect oldVideoHolderFrame;
  VideoDecoder* videoDecoder;
}

- (void)viewDidLoad {
  [super viewDidLoad];

  oldWindow = nil;
  oldContentView = nil;
  oldVideoHolderSuperview = nil;
  videoDecoder = [[VideoDecoder alloc] initWithController:self];

  // Listen to all the properties that might change in our model.
  [self.videoModel addObserver:self forKeyPath:@"layerClass" options:0 context:nil];
  [self.videoModel addObserver:self forKeyPath:@"buffering" options:0 context:nil];
  [self.videoModel addObserver:self forKeyPath:@"pixelBuffer" options:0 context:nil];
  [self.videoModel addObserver:self forKeyPath:@"videoFilename" options:0 context:nil];

  // Setup our initial video.
  [self clearVideo];
}

- (void)dealloc {
  [_layerClassPopUp release];
  [_bufferingPopUp release];
  [_pixelBufferOpenGLCompatibilityButton release];
  [_pixelBufferIOSurfaceCoreAnimationCompatibilityButton release];
  [_videoHolder release];

  [oldWindow release];
  [oldContentView release];
  [oldVideoHolderSuperview release];
  [videoDecoder release];
  [self.videoModel removeObserver:self forKeyPath:@"layerClass"];
  [self.videoModel removeObserver:self forKeyPath:@"buffering"];
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

- (void)windowWillEnterFullScreen:(NSNotification *)notification {
  oldWindow = [self.view.window retain];
  oldContentView = [oldWindow.contentView retain];
  oldVideoHolderSuperview = [self.videoHolder.superview retain];

  oldVideoHolderFrame = self.videoHolder.frame;

  [self.videoHolder removeFromSuperview];
  oldWindow.contentView = self.videoHolder;
}

- (void)windowWillExitFullScreen:(NSNotification *)notification {
  oldWindow.contentView = oldContentView;
  [oldVideoHolderSuperview addSubview:self.videoHolder];

  [oldVideoHolderSuperview release];
  oldVideoHolderSuperview = nil;
  [oldWindow release];
  oldWindow = nil;
  [oldContentView release];
  oldContentView = nil;
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
  self.videoHolder.frame = oldVideoHolderFrame;
}
@end
