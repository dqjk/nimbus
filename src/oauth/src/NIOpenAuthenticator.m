//
// Copyright 2012 Jeff Verkoeyen
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "NIOpenAuthenticator.h"

#import "NIOpenAuthenticator+Subclassing.h"
#import "NimbusCore+Additions.h"

static NSString* gApplicationRedirectBasePath = nil;
static NSMutableSet* gAuthenticators = nil;

@interface NIOpenAuthenticator()
@property (nonatomic, readwrite, assign) NIOpenAuthenticationState state;
@property (nonatomic, readwrite, copy) NIOpenAuthenticationBlock stateHandler;
@property (nonatomic, readwrite, copy) NSString* oauthCode;
@property (nonatomic, readwrite, copy) NSString* oauthToken;
@end

@implementation NIOpenAuthenticator

@synthesize authenticationUrl = _authenticationUrl;
@synthesize clientIdentifier = _clientIdentifier;
@synthesize clientSecret = _clientSecret;
@synthesize oauthCode = _oauthCode;
@synthesize oauthToken = _oauthToken;
@synthesize redirectBasePath = _redirectBasePath;
@synthesize state = _state;
@synthesize stateHandler = _stateHandler;
@synthesize tokenUrl = _tokenUrl;

- (void)dealloc {
  [gAuthenticators removeObject:self];

  NI_RELEASE_SAFELY(_authenticationUrl);
  NI_RELEASE_SAFELY(_clientIdentifier);
  NI_RELEASE_SAFELY(_clientSecret);
  NI_RELEASE_SAFELY(_oauthCode);
  NI_RELEASE_SAFELY(_oauthToken);
  NI_RELEASE_SAFELY(_redirectBasePath);
  NI_RELEASE_SAFELY(_stateHandler);
  NI_RELEASE_SAFELY(_tokenUrl);

  [super dealloc];
}

+ (void)initialize {
  gAuthenticators = NICreateNonRetainingMutableSet();
}

- (id)initWithClientIdentifier:(NSString *)clientIdentifier clientSecret:(NSString *)clientSecret redirectBasePath:(NSString *)redirectBasePath {
  if ((self = [super init])) {
    _clientIdentifier = [clientIdentifier copy];
    _clientSecret = [clientSecret copy];
    _redirectBasePath = [redirectBasePath copy];
    _state = NIOpenAuthenticationStateInactive;

    [gAuthenticators addObject:self];
  }
  return self;
}

- (id)initWithClientIdentifier:(NSString *)clientIdentifier clientSecret:(NSString *)clientSecret {
  return [self initWithClientIdentifier:clientIdentifier clientSecret:clientSecret redirectBasePath:nil];
}

- (void)authenticateWithStateHandler:(NIOpenAuthenticationBlock)stateHandler {
  self.stateHandler = stateHandler;
  NSURL* authenticationUrl = self.authenticationUrl;
  NIDASSERT(NIIsStringWithAnyText([authenticationUrl absoluteString]));

  [[UIApplication sharedApplication] openURL:authenticationUrl];
}

- (NSString *)redirectBasePath {
  if (nil == _redirectBasePath) {
    // If you don't provide a redirect path you must specify an application redirect path.
    NIDASSERT(NIIsStringWithAnyText(gApplicationRedirectBasePath));
    return gApplicationRedirectBasePath;
  }
  return _redirectBasePath;
}

- (NSString *)redirectPath {
  if ([self.redirectBasePath hasSuffix:@"/"]) {
    return [self.redirectBasePath stringByAppendingString:@"oauth"];
  } else {
    return [self.redirectBasePath stringByAppendingString:@"/oauth"];
  }
}

- (void)fetchToken {
  NSDictionary* bodyParts = [NSDictionary dictionaryWithObjectsAndKeys:
                             self.clientIdentifier, @"client_id",
                             self.clientSecret, @"client_secret",
                             @"authorization_code", @"grant_type",
                             self.redirectPath, @"redirect_uri",
                             self.oauthCode, @"code",
                             nil];

  NSMutableArray* flattenedBodyParts = [NSMutableArray arrayWithCapacity:[bodyParts count]];
  for (NSString* key in bodyParts) {
    [flattenedBodyParts addObject:[key stringByAppendingFormat:@"=%@",
                                   [[bodyParts objectForKey:key] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]]];
  }
  NSString* fullBody = [flattenedBodyParts componentsJoinedByString:@"&"];
  NSData* body = [fullBody dataUsingEncoding:NSUTF8StringEncoding];
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:self.tokenUrl
                                                         cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                     timeoutInterval:30];
  [request setHTTPMethod:@"POST"];
  [request setValue:[NSString stringWithFormat:@"%d", body.length] forHTTPHeaderField:@"Content-Length"];
  [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
  [request setHTTPBody:body];
  NINetworkActivityTaskDidStart();
  
  self.state = NIOpenAuthenticationStateFetchingToken;
  if (nil != self.stateHandler) {
    self.stateHandler(self, NIOpenAuthenticationStateFetchingToken, nil);
  }

  [NSURLConnection sendAsynchronousRequest:request
                                     queue:[Nimbus networkOperationQueue]
                         completionHandler:
   ^(NSURLResponse* response, NSData* data, NSError* error) {
     NINetworkActivityTaskDidFinish();

     NSString* result = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
     BOOL didFindToken = NO;
     id object = [result objectFromJSONString];
     if ([object isKindOfClass:[NSDictionary class]]) {
       NSDictionary* results = object;
       if ([results objectForKey:@"access_token"]) {
         self.oauthToken = [results objectForKey:@"access_token"];

         didFindToken = YES;
         self.state = NIOpenAuthenticationStateAuthorized;
         if (nil != self.stateHandler) {
           dispatch_async(dispatch_get_main_queue(), ^{
             self.stateHandler(self, NIOpenAuthenticationStateAuthorized, nil);
             self.stateHandler = nil;
           });
         }
       }
     }

     if (!didFindToken) {
       self.state = NIOpenAuthenticationStateInactive;
       if (nil != self.stateHandler) {
         dispatch_async(dispatch_get_main_queue(), ^{
           self.stateHandler(self, NIOpenAuthenticationStateFetchingToken, error);
           self.stateHandler = nil;
         });
       }
     }
   }];
}

+ (void)setApplicationRedirectBasePath:(NSString *)redirectBasePath {
  if (gApplicationRedirectBasePath != redirectBasePath) {
    [gApplicationRedirectBasePath release];
    gApplicationRedirectBasePath = [redirectBasePath copy];
  }
}

+ (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation {
  for (NIOpenAuthenticator* auth in gAuthenticators) {
    if ([url.absoluteString hasPrefix:auth.redirectPath]) {
      NSDictionary* query = [url.query queryContentsUsingEncoding:NSUTF8StringEncoding];
      NSString* code = [[query objectForKey:@"code"] objectAtIndex:0];
      NSString* error = [[query objectForKey:@"error"] objectAtIndex:0];
      NSString* errorDescription = [[query objectForKey:@"error_description"] objectAtIndex:0];
      if (nil != error) {
        // TODO: Better error handling.
        errorDescription = [errorDescription stringByReplacingOccurrencesOfString:@"+"
                                                                       withString:@" "];
        UIAlertView* alert = [[UIAlertView alloc] initWithTitle:@"Error"
                                                        message:errorDescription
                                                       delegate:nil
                                              cancelButtonTitle:nil
                                              otherButtonTitles:@"OK", nil];
        [alert show];

      } else if (nil != code) {
        auth.oauthCode = code;
        [auth fetchToken];
      }
      return YES;
    }
  }
  return NO;
}

@end

@implementation NISoundCloudOpenAuthenticator

- (NSString *)redirectPath {
  return [[super redirectPath] stringByAppendingString:@"/soundcloud"];
}

- (NSURL *)authenticationUrl {
  return [NSURL URLWithString:
          [NSString stringWithFormat:
           @"https://soundcloud.com/connect?client_id=%@&response_type=code&redirect_uri=%@&scope=non-expiring",
           self.clientIdentifier,
           self.redirectPath]];
}

- (NSURL *)tokenUrl {
  return [NSURL URLWithString:@"https://api.soundcloud.com/oauth2/token"];
}

@end