//
//  AutoreleasedLock.h
//  VideoPowerProto
//
//  Created by Brad Werth on 8/18/21.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AutoreleasedLock : NSObject

+ (instancetype)lock:(id<NSLocking>)lock;

@end

NS_ASSUME_NONNULL_END
