//
//  DPHue.m
//  DPHue
//
//  This class is in the public domain.
//  Originally created by Dan Parsons in 2012.
//
//  https://github.com/danparsons/DPHue

#import "DPHue.h"
#import "DPHueLight.h"
#import "DPHueLightGroup.h"
#import "DPJSONConnection.h"
#import "NSString+MD5.h"
#import "WSLog.h"
#import <CocoaAsyncSocket/GCDAsyncSocket.h>


@interface DPHue () <GCDAsyncSocketDelegate>

// JPR TODO: allow setting from the outside
@property (nonatomic, strong) NSString *deviceType;
@property (nonatomic, strong) GCDAsyncSocket *socket;
@property (nonatomic, copy) void (^touchLightCompletionBlock)(BOOL success, NSString *result);

@end


@implementation DPHue

- (id)initWithHueHost:(NSString *)host generatedUsername:(NSString *)generatedUsername
{
  if ( self = [super init] )
  {
    _deviceType = @"QuickHue";
    _authenticated = NO;
    _host = host;
    _generatedUsername = generatedUsername;
  }
  
  return self;
}

#pragma mark - NSCoding

- (id)initWithCoder:(NSCoder *)a {
  self = [super init];
  if (self) {
    _deviceType = @"QuickHue";
    _generatedUsername = [a decodeObjectForKey:@"generatedUsername"];
    _host = [a decodeObjectForKey:@"host"];
    _lights = [a decodeObjectForKey:@"lights"];
    _groups = [a decodeObjectForKey:@"groups"];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)a {
  [a encodeObject:_host forKey:@"host"];
  [a encodeObject:_lights forKey:@"lights"];
  [a encodeObject:_groups forKey:@"groups"];
  [a encodeObject:_generatedUsername forKey:@"generatedUsername"];
}

- (void)setGeneratedUsername:(NSString *)generatedUsername
{
  _generatedUsername = generatedUsername;
  
  // As each DPHueLight and DPHueLightGroup maintains its own access URLs, they
  // too must be updated if URLs change.
  for (DPHueLight *light in self.lights)
  {
    light.username = generatedUsername;
  }
  
  for (DPHueLightGroup *group in self.groups)
  {
    group.username = generatedUsername;
  }
}

- (void)setHost:(NSString *)host
{
  _host = host;
  
  // As each DPHueLight and DPHueLightGroup maintains its own access URLs, they
  // too must be updated if URLs change.
  for (DPHueLight *light in self.lights)
  {
    light.host = host;
  }
  
  for (DPHueLightGroup *group in self.groups)
  {
    group.host = host;
  }
}

- (void)readWithCompletion:(void (^)(DPHue *, NSError *))block
{
  // Cut down on if-checks within completionBlock
  void (^innerBlock)(DPHue *, NSError *) = ^(DPHue *hue, NSError *error) {
    if ( block )
      block(hue, error);
  };
  
  NSURLRequest *request = [self requestForReadingControllerState];
  
  DPJSONConnection *connection = [[DPJSONConnection alloc] initWithRequest:request sender:self];
  connection.completionBlock = ^(DPHue *sender, id json, NSError *err) {
    if ( err )
    {
      innerBlock( nil, err );
      return;
    }
    
    [sender parseControllerState:json];
    innerBlock( sender, nil );
  };
  
  [connection start];
}

- (void)registerDevice
{
  NSURLRequest *request = [self requestForRegisteringDevice:self.deviceType];
  
  DPJSONConnection *connection = [[DPJSONConnection alloc] initWithRequest:request sender:self];
  connection.completionBlock = ^(DPHue *sender, id json, NSError *err) {
    if ( err )
      return;
    
    [sender parseDeviceRegistration:json];
  };
  
  [connection start];
}

- (NSString *)description {
    NSMutableString *descr = [[NSMutableString alloc] init];
    [descr appendFormat:@"Name: %@\n", self.name];
    [descr appendFormat:@"Version: %@\n", self.swversion];
    [descr appendFormat:@"Number of lights: %lu\n", (unsigned long)self.lights.count];
    for (DPHueLight *light in self.lights) {
        [descr appendString:light.description];
        [descr appendString:@"\n"];
    }
    for (DPHueLightGroup *group in self.groups) {
        [descr appendString:group.description];
        [descr appendString:@"\n"];
    }
    return descr;
}

- (void)triggerTouchlinkWithCompletion:(void (^)(BOOL success, NSString *))block {
    WSLog(@"Triggering Touchlink");
    self.socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
    NSError *err = nil;
    if (![self.socket connectToHost:self.host onPort:30000 withTimeout:5 error:&err]) {
        WSLog(@"Error connecting to %@:30000 %@", self.host, err);
        return;
    }
    self.touchLightCompletionBlock = block;
    // After 10 seconds, stop
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 10), dispatch_get_main_queue(), ^{
        if (self.socket) {
            self.touchLightCompletionBlock(NO, @"No response after 10 sec");
            [self.socket disconnect];
            self.socket = nil;
        }
    });
}

- (DPHueLight *)lightWithId:(NSNumber *)lightId
{
  for ( DPHueLight *light in self.lights )
  {
    if ( [light.number isEqualToNumber:lightId] )
      return light;
  }
  
  return nil;
}

- (DPHueLight *)lightWithName:(NSString *)lightName
{
  for ( DPHueLight *light in self.lights )
  {
    if ( [light.name isEqualToString:lightName] )
      return light;
  }
  
  return nil;
}

- (DPHueLightGroup *)groupWithId:(NSNumber *)groupId
{
  for ( DPHueLightGroup *group in self.groups )
  {
    if ( [group.number isEqualToNumber:groupId] )
      return group;
  }
  
  return nil;
}

- (DPHueLightGroup *)groupWithName:(NSString *)groupName
{
  for ( DPHueLightGroup *group in self.groups )
  {
    if ( [group.name isEqualToString:groupName] )
      return group;
  }
  
  return nil;
}

- (void)createGroupWithName:(NSString *)name lightIds:(NSArray *)lightIds onCompletion:(void (^)(BOOL success, DPHueLightGroup *group))onCompletionBlock
{
  // JPR TODO: handle lights being off during creation
  
  DPHueLightGroup *group = [DPHueLightGroup new];
  group.username = self.generatedUsername;
  group.host = self.host;
  NSURLRequest *request = [group requestForCreatingWithName:name lightIds:lightIds];
  DPJSONConnection *conn = [[DPJSONConnection alloc] initWithRequest:request sender:self];
  if ( onCompletionBlock )
  {
    conn.completionBlock = ^(DPHue *sender, id json, NSError *err) {
      if ( err )
      {
        onCompletionBlock( NO, nil );
        return;
      }
      
      [group parseGroupCreation:json];
      onCompletionBlock( YES, group);
    };
  }
  
  [conn start];
}

- (void)updateGroup:(DPHueLightGroup *)group withName:(NSString *)name lightIds:(NSArray *)lightIds onCompletion:(void (^)(BOOL success, DPHueLightGroup *group))onCompletionBlock
{
  // JPR TODO: handle lights being off during creation
  
  if ( !name )
    name = group.name;
  
  NSURLRequest *request = [group requestForUpdatingWithName:name lightIds:lightIds];
  DPJSONConnection *conn = [[DPJSONConnection alloc] initWithRequest:request sender:self];
  if ( onCompletionBlock )
  {
    conn.completionBlock = ^(DPHue *sender, id json, NSError *err) {
      if ( err )
      {
        onCompletionBlock( NO, nil );
        return;
      }
      
      [group parseGroupUpdate:json];
      onCompletionBlock( YES, group);
    };
  }
  
  [conn start];
}

#pragma mark - GCDAsyncSocketDelegate

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port {
    WSLog(@"Connected to %@:%d", host, port);
    NSData *data = [@"[Link,Touchlink]\n" dataUsingEncoding:NSUTF8StringEncoding];
    [sock writeData:data withTimeout:-1 tag:-1];
    NSMutableData *buffy = [[NSMutableData alloc] init];
    [self.socket readDataToData:[GCDAsyncSocket LFData] withTimeout:5 buffer:buffy bufferOffset:0 tag:-1];
    WSLog(@"Sending: %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
}

- (void)socket:(GCDAsyncSocket *)sender didReadData:(NSData *)data withTag:(long)tag {
    NSMutableData *buffy = [[NSMutableData alloc] init];
    NSString *resultMsg = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    WSLog(@"Received string: %@", resultMsg);
    if ([resultMsg rangeOfString:@"[Link,Touchlink,success"].location != NSNotFound) {
        // Touchlink found bulbs
        self.touchLightCompletionBlock(YES, resultMsg);
        [self.socket disconnect];
        self.socket = nil;
    } else if ([resultMsg rangeOfString:@"[Link,Touchlink,failed"].location != NSNotFound) {
        // Touchlink failed to find bulbs
        self.touchLightCompletionBlock(NO, resultMsg);
        [self.socket disconnect];
        self.socket = nil;
    } else {
        // We do not have a Touchlink result message yet, so keep receiving
        [self.socket readDataToData:[GCDAsyncSocket LFData] withTimeout:5 buffer:buffy bufferOffset:0 tag:-1];
    }
}


#pragma mark - HueAPIRequestGeneration

- (NSURLRequest *)requestForRegisteringDevice:(NSString *)deviceType
{
  NSAssert([self.host length], @"No host set");
  
  NSString *urlPath = [NSString stringWithFormat:@"http://%@/api", self.host];
  NSURL *url = [NSURL URLWithString:urlPath];
  
  NSDictionary *postData = @{@"devicetype": deviceType};
  // JPR TODO: pass and check error
  NSData *postJson = [NSJSONSerialization dataWithJSONObject:postData options:0 error:nil];
  NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url];
  request.HTTPMethod = @"POST";
  request.HTTPBody = postJson;
  
  return request;
}

- (NSURLRequest *)requestForReadingControllerState
{
  NSAssert([self.host length], @"No host set");
  
  NSString *urlPath = [NSString stringWithFormat:@"http://%@/api/%@",
                       self.host, self.generatedUsername];
  NSURL *url = [NSURL URLWithString:urlPath];
  
  NSURLRequest *request = [NSURLRequest requestWithURL:url];
  return request;
}


#pragma mark - HueAPIJsonParsing

// POST /
- (instancetype)parseDeviceRegistration:(id)json
{
  if ( [json respondsToSelector:@selector(firstObject)]
      && [[json firstObject] isKindOfClass:[NSDictionary class]]
      && [json firstObject][@"success"][@"username"] )
  {
    _generatedUsername = [json firstObject][@"success"][@"username"];
    _authenticated = YES;
  }
  else
  {
    _generatedUsername = nil;
    _authenticated = NO;
  }
  
  return self;
}

// GET /{username}
- (instancetype)parseControllerState:(id)json
{
  if ( ![json respondsToSelector:@selector(objectForKeyedSubscript:)] )
  {
    // We were given an array, not a dict, which means
    // Hue is giving us a result array, which (in this case)
    // means error: not authenticated
    _authenticated = NO;
    return self;
  }
  
  _name = json[@"config"][@"name"];
  if ( _name )
  {
    _authenticated = YES;
  }
  
  _swversion = json[@"config"][@"swversion"];
  
  NSNumberFormatter *f = [NSNumberFormatter new];
  f.numberStyle = NSNumberFormatterDecimalStyle;
  
  NSMutableArray *tmpLights = [NSMutableArray new];
  for ( NSString *lightItem in json[@"lights"] )
  {
    DPHueLight *light = [DPHueLight new];
    [light parseLightStateGet:json[@"lights"][lightItem]];
    light.number = [f numberFromString:lightItem];
    light.username = self.generatedUsername;
    light.host = self.host;
    [tmpLights addObject:light];
  }
  _lights = tmpLights;
  
  NSMutableArray *tmpGroups = [NSMutableArray new];
  for ( NSString *groupItem in json[@"groups"] )
  {
    DPHueLightGroup *group = [DPHueLightGroup new];
    [group parseGroupStateGet:json[@"groups"][groupItem]];
    group.number = [f numberFromString:groupItem];
    group.username = self.generatedUsername;
    group.host = self.host;
    [tmpGroups addObject:group];
  }
  _groups = tmpGroups;
  
  return self;
}

@end
