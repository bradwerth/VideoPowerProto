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
  VideoDecoder* videoDecoder;
}

- (void)viewDidLoad {
  [super viewDidLoad];

  videoDecoder = [[VideoDecoder alloc] initWithController:self];

  // Listen to all the properties that might change in our model.
  [self.videoModel addObserver:self forKeyPath:@"layerClass" options:0 context:nil];
  [self.videoModel addObserver:self forKeyPath:@"buffering" options:0 context:nil];
  [self.videoModel addObserver:self forKeyPath:@"pixelBuffer" options:0 context:nil];
  [self.videoModel addObserver:self forKeyPath:@"videoFilename" options:0 context:nil];

  // Setup our initial videoHolder and videoDecoder.
  [self resetVideoHolder];
  [self resetVideoDecoder];
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
  self.videoModel.pixelBuffer = (isOn ? (oldValue |= sender.tag) : (oldValue &= ~sender.tag));
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context {
  // All changes to the model require resetting the videoHolder and
  // videoDecoder, in that order.
  [self resetVideoHolder];
  [self resetVideoDecoder];
}

- (void)resetVideoDecoder {
  [videoDecoder resetWithModel:self.videoModel];
}

- (void)resetVideoHolder {
  [self.videoHolder resetWithModel:self.videoModel];
}

- (BOOL)wantsMoreFrames {
  return [self.videoHolder wantsMoreFrames];
}

- (BOOL)handleDecodedFrame:(CMSampleBufferRef)buffer {
  return [self.videoHolder handleDecodedFrame:buffer];
}

- (void)requestFrames {
  [videoDecoder requestFrames];
}

@end
