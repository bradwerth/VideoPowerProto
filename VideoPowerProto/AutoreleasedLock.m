//
//  AutoreleasedLock.m
//  VideoPowerProto
//
//  Created by Brad Werth on 8/18/21.
//

#import "AutoreleasedLock.h"

@implementation AutoreleasedLock

id<NSLocking> lock;

+ (instancetype)lock:(id<NSLocking>)lock {
  return [[[AutoreleasedLock alloc] initWithLock:lock] autorelease];
}

- (instancetype)initWithLock:(id<NSLocking>)inLock {
  self = [super init];
  lock = inLock;
  [lock lock];
  return self;
}

- (void)dealloc {
  [lock unlock];
  [super dealloc];
}

@end
