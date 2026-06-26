#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ABContentBlockerRules : NSObject

@property(nonatomic, copy, readonly) NSString *json;
@property(nonatomic, readonly, getter=isTruncated) BOOL truncated;
@property(nonatomic, readonly) uint64_t unsupportedRulesCount;

- (instancetype)init NS_UNAVAILABLE;

@end

@interface ABNetworkRequestResult : NSObject

@property(nonatomic, readonly) BOOL matched;
@property(nonatomic, readonly) BOOL important;
@property(nonatomic, copy, readonly) NSString *redirect;
@property(nonatomic, copy, readonly) NSString *rewrittenURL;
@property(nonatomic, copy, readonly) NSString *exception;
@property(nonatomic, copy, readonly) NSString *filter;
@property(nonatomic, copy, readonly) NSString *cspDirectives;

- (instancetype)init NS_UNAVAILABLE;

@end

@interface ABAdblockEngine : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithFilterSet:(NSString *)filterSet
    NS_DESIGNATED_INITIALIZER NS_SWIFT_NAME(init(filterSet:));
- (instancetype)initWithSerializedData:(NSData *)serializedData
    NS_DESIGNATED_INITIALIZER NS_SWIFT_NAME(init(serializedData:));

+ (ABContentBlockerRules *)contentBlockerRulesFromFilterSet:(NSString *)filterSet
    NS_SWIFT_NAME(contentBlockerRules(fromFilterSet:));
+ (ABContentBlockerRules *)contentBlockerRulesFromFilterSet:(NSString *)filterSet
                                                  ruleLimit:(NSUInteger)ruleLimit
    NS_SWIFT_NAME(contentBlockerRules(fromFilterSet:ruleLimit:));
+ (NSString *)defaultResourcesJSON NS_SWIFT_NAME(defaultResourcesJSON());

- (NSData *)serializedData NS_SWIFT_NAME(serializedData());
- (void)useResourcesJSON:(NSString *)json NS_SWIFT_NAME(useResources(json:));
- (NSString *)cosmeticResourcesForURL:(NSString *)url NS_SWIFT_NAME(cosmeticResources(for:));
- (NSString *)cosmeticResourcesForURL:(NSString *)url
                            topFrame:(BOOL)topFrame
    NS_SWIFT_NAME(cosmeticResources(for:topFrame:));
- (ABNetworkRequestResult *)checkNetworkRequestWithURL:(NSString *)url
                                             sourceURL:(NSString *)sourceURL
                                           requestType:(NSString *)requestType
    NS_SWIFT_NAME(checkNetworkRequest(url:sourceURL:requestType:));
- (NSString *)stylesheetForCosmeticRulesWithClasses:(NSArray<NSString *> *)classes
                                                ids:(NSArray<NSString *> *)ids
                                     exceptionsJSON:(NSString *)exceptionsJSON
    NS_SWIFT_NAME(stylesheetForCosmeticRules(classes:ids:exceptionsJSON:));
- (NSArray<NSString *> *)selectorsForCosmeticRulesWithClasses:(NSArray<NSString *> *)classes
                                                          ids:(NSArray<NSString *> *)ids
                                               exceptionsJSON:(NSString *)exceptionsJSON
    NS_SWIFT_NAME(selectorsForCosmeticRules(classes:ids:exceptionsJSON:));

@end

NS_ASSUME_NONNULL_END
