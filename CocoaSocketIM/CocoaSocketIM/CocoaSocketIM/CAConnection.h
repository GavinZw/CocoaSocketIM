//
//  CAConnection.h
//  CocoaSocketIM
//
//  Created by Gavin on 2017/8/16.
//  Copyright © 2017年 Gavin. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <ReactiveObjC/ReactiveObjC.h>
// http://www.cocoachina.com/ios/20170209/18657.html
typedef NS_ENUM(NSUInteger, CAConnectionStatus) {
  CAConnectionStatus_Init = 0,
  CAConnectionStatus_Connecting,
  CAConnectionStatus_Authorizing,
  CAConnectionStatus_Open,
  CAConnectionStatus_Closing,
  CAConnectionStatus_Closed
};

@protocol CAConnectDelegate;

@interface CAConnection : NSObject

@property (nonatomic, assign, readonly) CAConnectionStatus status;

@property (nonatomic, strong, readonly) NSString *version;
@property (nonatomic, strong, readonly) NSString *host;
@property (nonatomic, assign, readonly) NSUInteger port;

@property (nonatomic, readonly, getter=isConnected) BOOL connected;

@property (nonatomic, assign) id<CAConnectDelegate> delegate;

- (instancetype)initWithHost:(NSString *)aHost port:(NSUInteger)aPort secure:(BOOL)secure delegate:(id<CAConnectDelegate>)delegate;

- (void)open;
- (void)close;

- (void)sendMessage:(NSDictionary *)message timeOut:(NSUInteger)timeOut tag:(long)tag;

@property (nonatomic, strong, readonly) RACSignal *errorSignal;        //when connect error or connect failed.

@end


@interface CAConnection (Operation)

/**
 读取服务端数据
 */
- (void)_readDataWithTimeout:(NSTimeInterval)timeout tag:(long)tag;

/**
 发送数据服务端
 */
- (void)_writeData:(NSData *)data timeout:(NSTimeInterval)timeout tag:(long)tag;

/**
 对发送给服务端数据进行封包
 */
- (NSData *)_writeDataPacking:(NSData *)data;

/**
 对发送给服务端数据进行拆包
 */
- (void)_socket:(GCDAsyncSocket *)sock writeDataUnpacking:(NSData *)data successBlock:(void (^)(NSString *type))block;

@end


@protocol CAConnectDelegate <NSObject>

@optional
- (void)cocoaIMConnectDidOpen:(CAConnection *)connect;
- (void)cocoaIMConnectDidClose:(CAConnection *)connect;
- (void)cocoaIMConnect:(CAConnection *)connect didReceiveMessage:(id)message;
- (void)cocoaIMConnect:(CAConnection *)connect didError:(NSError *)error;

@end

