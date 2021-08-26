//
//  AutoreleasedLock.m
//  VideoPowerProto
//
//  Created by Brad Werth on 8/18/21.
//

#import "AutoreleasedLock.h"

@interface AutoreleasedLock ()
@property (nonatomic, retain) id<NSLocking> lock;
@end

@implementation AutoreleasedLock

+ (instancetype)lock:(id<NSLocking>)lock {
  return [[[AutoreleasedLock alloc] initWithLock:lock] autorelease];
}

- (instancetype)initWithLock:(id<NSLocking>)lock {
  self = [super init];
  self.lock = lock;
  [self.lock lock];
  return self;
}

- (void)dealloc {
  [self.lock unlock];
  [super dealloc];
}

@end
