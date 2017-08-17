//
//  NSDictionary+Serialization.m
//  CocoaSocketIM
//
//  Created by Gavin on 2017/8/16.
//  Copyright © 2017年 Gavin. All rights reserved.
//

#import "NSDictionary+Serialization.h"

@implementation NSDictionary (Serialization)

- (NSString *)ca_jsonString {
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:self options:0 error:&error];
  if (!error) {
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return json;
  } else {
    @throw [NSException exceptionWithName:@"json serialize error" reason:@"dictionary to json serialize failed" userInfo:nil];
  }
}


@end
