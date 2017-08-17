//
//  NSString+Serialization.m
//  CocoaSocketIM
//
//  Created by Gavin on 2017/8/16.
//  Copyright © 2017年 Gavin. All rights reserved.
//

#import "NSString+Serialization.h"

@implementation NSString (Serialization)

+ (NSDictionary *)dictionaryFromJson:(NSString *)json{
  if (json != nil) {
    NSError *error = nil;
    NSData *jsonData = [json dataUsingEncoding:NSUTF8StringEncoding];
    
    id jsonParsedObj = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    
    if (error == nil) {
      if ([jsonParsedObj isKindOfClass:[NSDictionary class]]) {
        return (NSDictionary *) jsonParsedObj;
      }
    } else {
      NSLog(@"Failed parsing JSON: %@", error);
    }
  }
  
  return @{};
}

@end
