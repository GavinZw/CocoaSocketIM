//
//  CAConnection.m
//  CocoaSocketIM
//
//  Created by Gavin on 2017/8/16.
//  Copyright © 2017年 Gavin. All rights reserved.
//
#import <CocoaAsyncSocket/GCDAsyncSocket.h>

#import "CATimer.h"
#import "CAConnection.h"
#import "NSString+Serialization.h"
#import "NSDictionary+Serialization.h"

#ifdef DEBUG
#define CALog(fmt, ...) NSLog((@"%s [Line %d] " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__);
#else
#define CALog(...)
#endif

#define INIT(...) self = super.init; \
if (!self) return nil; \
__VA_ARGS__; \
_lock = dispatch_semaphore_create(1); \
return self;


#define LOCK(...) dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER); \
__VA_ARGS__; \
dispatch_semaphore_signal(_lock);

typedef NS_ENUM (NSInteger, CASocketOfflineType){
  CASocketOfflineType_Server,  // 服务器掉线
  CASocketOfflineType_User,    // 用户主动 cut
};

typedef NS_ENUM(NSUInteger, CAConnectionReqType) {
  CAConnectionReqType_None = 0,
  CAConnectionReqType_Connect,
  CAConnectionReqType_Auth,
  CAConnectionReqType_Data,
};

NSString *_SlimConnectionReqTypeName(CAConnectionReqType t) {
  static NSString *type[] = {
    [CAConnectionReqType_Connect] = @"conn_req",
    [CAConnectionReqType_Auth] = @"auth",
    [CAConnectionReqType_Data] = @"data",
  };
  return type[t];
}

typedef NS_ENUM(NSUInteger, CASocketUnPacketHeadErrorType) {
  CASocketUnPacketHeadErrorType_None = 0,           // 有效的数据
  CASocketUnPacketHeadErrorType_UnPacketing,        // 正在拆包
  CASocketUnPacketHeadErrorType_HeadNil,            // 数据包头为空
  CASocketUnPacketHeadErrorType_DataLength,         // 数据包的长度不一样
  CASocketUnPacketHeadErrorType_DataInvalid,        // 数据为空,或者无效的数据
};

@interface CAConnection () <
 GCDAsyncSocketDelegate
>

@property (nonatomic, strong) GCDAsyncSocket *asyncSocket;

@property (nonatomic, strong) NSMutableArray *asyncSockets;

@property (nonatomic) NSInteger autoConnectCount; // default 3.
@property (nonatomic) CASocketUnPacketHeadErrorType   unPacketHeadErrorType;

@end

@implementation CAConnection {
  NSDictionary *_currentPacketHead;
  
  dispatch_semaphore_t _lock;
  RACSubject *_errorSubject;
  RACDisposable *_heartbeatDiposable;
}

@synthesize errorSignal = _errorSubject;

#pragma mark - lifecycle

- (void)dealloc {
   [self close];
   [self releaseHearbeat];
  
   [_errorSubject sendCompleted];
  _asyncSocket.delegate = nil;
  _asyncSocket = nil;
  
}

- (instancetype)initWithHost:(NSString *)aHost port:(NSUInteger)aPort secure:(BOOL)secure delegate:(id<CAConnectDelegate>)delegate{
  NSParameterAssert(aHost);
  NSParameterAssert(aPort);
  NSParameterAssert(delegate);
  
  // init code
  INIT(
       _delegate = delegate;
       _host = [aHost copy];
       _port = aPort;
       _status = CAConnectionStatus_Init;
       _version = @"s.t.0.1";
       _autoConnectCount = 3;
       
       _asyncSocket = [[GCDAsyncSocket alloc] initWithDelegate:self  delegateQueue:dispatch_get_main_queue()];
       [_asyncSocket setAutoDisconnectOnClosedReadStream:NO];
       
       _asyncSockets = @[].mutableCopy;
       _errorSubject = [RACSubject subject];
     )
}

#pragma mark - properties

- (void)setStatus:(CAConnectionStatus)status{
  LOCK(_status = status;)
}

#pragma mark - private funcs

- (void)_connectWithHost:(NSString *)hostName port:(uint16_t)port{
  NSError *error = nil;
  
  [_asyncSocket connectToHost:hostName onPort:port error:&error];
  if (error) {
     CALog(@"connect error: %@", error.description);
    if (_delegate && [_delegate respondsToSelector:@selector(cocoaIMConnect:didError:)]) {
      [_delegate cocoaIMConnect:self didError:error];
    }
  }
}

- (void)setupHeartbeat {
  NSTimeInterval heartbeat = 60 * 3;      //心跳间隔 3 分钟
  @weakify(self);
  _heartbeatDiposable = [[RACSignal interval:heartbeat
                                 onScheduler:[RACScheduler scheduler]]
                         subscribeNext:^(id _) {
    @strongify(self);
    CALog(@"[PING]");

    [self _writeData: [@{@"head" : @"",
                         @"body" : @(1314),
                         @"end" : @(1)
                        }.ca_jsonString dataUsingEncoding:NSUTF8StringEncoding]
             timeout:1
                 tag:0];
  }];
}

- (void)releaseHearbeat {
  if (_heartbeatDiposable) {
    [_heartbeatDiposable dispose];
    _heartbeatDiposable = nil;
  }
}

- (void)_sendError:(NSError *)error {
  [_errorSubject sendNext:error];
}

#pragma mark - public funcs

- (void)connect{
  NSParameterAssert(_host);
  NSParameterAssert(_port);
  
  LOCK([self _connectWithHost:_host port:_port];)
}

- (void)disconnect{
  LOCK(
       _asyncSocket.userData = @(CASocketOfflineType_User);
       )
}

- (BOOL)isConnected{
  LOCK(BOOL c = [_asyncSocket isConnected];); return c;
}

- (void)_disconnect{
  //断开连接
  [_asyncSocket disconnect];
  _autoConnectCount = 0;
}

- (void)sendMessage:(NSDictionary *)message timeOut:(NSUInteger)timeOut tag:(long)tag{
  NSParameterAssert(self.status == CAConnectionStatus_Open);
  
  //将模型转换为json字符串
  NSString *messageJson = message.ca_jsonString;
  //以"\n"分割此条消息 , 支持的分割方式有很多种例如\r\n、\r、\n、空字符串,不支持自定义分隔符,具体的需要和服务器协商分包方式 , 这里以\n分包
  /*
   如不进行分包,那么服务器如果在短时间里收到多条消息 , 那么就会出现粘包的现象 , 无法识别哪些数据为单独的一条消息 .
   对于普通文本消息来讲 , 这里的处理已经基本上足够 . 但是如果是图片进行了分割发送,就会形成多个包 , 那么这里的做法就显得并不健全,严谨来讲,应该设置包头,把该条消息的外信息放置于包头中,例如图片信息,该包长度等,服务器收到后,进行相应的分包,拼接处理.
   */
  messageJson           = [messageJson stringByAppendingString:@"\n"];
  //base64编码成data
  NSData  *messageData  = [[NSData alloc]initWithBase64EncodedString:messageJson options:NSDataBase64DecodingIgnoreUnknownCharacters];
  

  // 数据封包
  NSData *data = [self _writeDataPacking:messageData];

  //写入数据
  [self _writeData:data timeout:timeOut tag:tag];
}

#pragma mark -
#pragma mark -  GCDAsyncSocketDelegate

- (BOOL)_responseCheck:(NSDictionary *)res {
  return true;
}

/** 接收到 socket 连接.
 * 这里需要注意的是，成功接收到连接后，调用代理我们必须把新生成的这个newSocket保存起来.
 * 如果它被销毁了，那么连接就断开了，这里我们把它放到了一个数组中去了。
 */
- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)newSocket{
  CALog(@"[CAConnection] didAcceptNewSocket...接收到 socket 连接.");
  
  LOCK( [_asyncSockets addObject:newSocket];)
  [newSocket readDataToData:[GCDAsyncSocket CRLFData] withTimeout:-1 tag:110];
}

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag{
  CALog(@"[CAConnection] didReadData length: %lu, tag: %ld", (unsigned long)data.length, tag);
  
  // 拆包
  [self _socket:sock writeDataUnpacking:data
   successBlock:^(NSString *type) {
     
   }];
  
  NSString *message = [[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
  
  if (_delegate && [_delegate respondsToSelector:@selector(cocoaIMConnect:didReceiveMessage:)]) {
    [_delegate cocoaIMConnect:self didReceiveMessage:message];
  }
  
  
}



- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(nullable NSError *)err{
  //如果是用户主动断开连接
  CASocketOfflineType offline = [_asyncSocket.userData integerValue];
  if (offline == CASocketOfflineType_User){
    CALog(@"用户主动断开连接");
  }
  
  else if(offline == CASocketOfflineType_Server){ // 服务器掉线,自动重连
      CALog(@"[CAConnection] socketDidDisconnect...%@", err.description);
  };
  

  

  
  if (_delegate && [_delegate respondsToSelector:@selector(cocoaIMConnect:didError:)]) {
    [_delegate cocoaIMConnect:self didError:err];
  }
}

/** 连接服务成功. */
- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port{
  CALog(@"[CAConnection] didConnectToHost: %@, port: %d", host, port);
  if (_delegate && [_delegate respondsToSelector:@selector(cocoaIMConnectDidOpen:)]) {
    [_delegate cocoaIMConnectDidOpen:self];
  }
}

- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag{
  CALog(@"[CAConnection] didWriteDataWithTag: %ld", tag);
  [sock readDataWithTimeout:-1 tag:tag];
}

@end


@implementation CAConnection (Operation)

/**
 读取服务端数据
 */
- (void)_readDataWithTimeout:(NSTimeInterval)timeout tag:(long)tag{
  [_asyncSocket readDataWithTimeout:timeout tag:tag];
}

/**
 发送数据服务端
 */
- (void)_writeData:(NSData *)data timeout:(NSTimeInterval)timeout tag:(long)tag{
  [_asyncSocket writeData:data withTimeout:timeout tag:tag];
}

/**
 对发送给服务端数据进行封包
 */
- (NSData *)_writeDataPacking:(NSData *)data{
  NSUInteger size = data.length;
  NSDictionary *head = @{@"size" : [NSString stringWithFormat:@"%ld",(long)size],
                         };
  NSData *lengthData = [head.ca_jsonString dataUsingEncoding:NSUTF8StringEncoding];
  
  // 分界
  NSMutableData *tempData = [NSMutableData dataWithData:lengthData];
  [tempData appendData:[GCDAsyncSocket CRLFData]];
  [tempData appendData:data];
  
  return tempData;
}

/**
 对发送给服务端数据进行拆包
 
 这个方法也很简单，我们判断，如果currentPacketHead（当前数据包的头部）为空，则说明这次读取，是一个头部信息，
 我们去获取到该数据包的头部信息。并且调用下一次读取，读取长度为从头部信息中取出来的数据包长度：
 
 */
- (void)_socket:(GCDAsyncSocket *)sock writeDataUnpacking:(NSData *)data{
  
    _unPacketHeadErrorType = CASocketUnPacketHeadErrorType_UnPacketing;
  
  // 1. 先读取到当前数据包头部信息
  if (!_currentPacketHead) {
    _currentPacketHead = [NSJSONSerialization
                          JSONObjectWithData:data
                          options:NSJSONReadingMutableContainers
                          error:nil];
    
    NSUInteger packetLength = [_currentPacketHead[@"size"] integerValue];
    //读到数据包的大小
    [sock readDataToLength:packetLength withTimeout:-1 tag:110];
    
    return;
  }
  
  
  if (!_currentPacketHead) {
    CALog(@"error：当前数据包的头为空");
    // 断开这个socket连接或者丢弃这个包的数据进行下一个包的读取
    //    [self disConnect];
     _unPacketHeadErrorType = CASocketUnPacketHeadErrorType_HeadNil;
    return;
  }
  
  //正式的包处理
  NSUInteger packetLength = [_currentPacketHead[@"size"] integerValue];
  //说明数据有问题
  if (packetLength <= 0 || data.length != packetLength) {
    CALog(@"error：当前数据包数据大小不正确");
    //    [self disConnect];
    
    _unPacketHeadErrorType  = (packetLength <= 0)? CASocketUnPacketHeadErrorType_DataInvalid : CASocketUnPacketHeadErrorType_DataLength;
    return;
  }
  
  NSString *type = _currentPacketHead[@"type"];

  _currentPacketHead = nil;
  _unPacketHeadErrorType = CASocketUnPacketHeadErrorType_None;
  
  [sock readDataToData:[GCDAsyncSocket CRLFData] withTimeout:-1 tag:110];
}

@end
