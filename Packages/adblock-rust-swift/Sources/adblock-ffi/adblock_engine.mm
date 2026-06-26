#import "adblock_engine.h"

#include <memory>

#include "adblock_ffi/src/lib.rs.h"
#include "rust/cxx.h"

static rust::String ABRustStringFromNSString(NSString *value) {
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) {
        return rust::String();
    }

    return rust::String(static_cast<const char *>(data.bytes), data.length);
}

static NSString *ABNSStringFromRustString(const rust::String &value) {
    NSString *string = [[NSString alloc] initWithBytes:value.data()
                                                length:value.size()
                                              encoding:NSUTF8StringEncoding];
    return string ?: @"";
}

static rust::Vec<uint8_t> ABRustBytesFromNSData(NSData *data) {
    rust::Vec<uint8_t> result;
    result.reserve(data.length);

    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
    for (NSUInteger index = 0; index < data.length; index++) {
        result.push_back(bytes[index]);
    }

    return result;
}

static NSData *ABNSDataFromRustBytes(const rust::Vec<uint8_t> &value) {
    return [NSData dataWithBytes:value.data() length:value.size()];
}

static rust::Vec<rust::String>
ABRustStringVectorFromNSArray(NSArray<NSString *> *values) {
    rust::Vec<rust::String> result;
    for (NSString *value in values) {
        result.push_back(ABRustStringFromNSString(value));
    }
    return result;
}

static NSArray<NSString *> *
ABNSArrayFromRustStringVector(const rust::Vec<rust::String> &values) {
    NSMutableArray<NSString *> *result =
        [NSMutableArray arrayWithCapacity:values.size()];
    for (const auto &value : values) {
        [result addObject:ABNSStringFromRustString(value)];
    }
    return result;
}

@interface ABContentBlockerRules ()

- (instancetype)initWithResult:(adblock_ffi::ContentBlockerResult)result;

@end

@implementation ABContentBlockerRules {
    NSString *_json;
    BOOL _truncated;
    uint64_t _unsupportedRulesCount;
}

- (instancetype)initWithResult:(adblock_ffi::ContentBlockerResult)result {
    self = [super init];
    if (self) {
        _json = [ABNSStringFromRustString(result.json) copy];
        _truncated = result.truncated;
        _unsupportedRulesCount = result.unsupported_rules;
    }
    return self;
}

- (NSString *)json {
    return _json;
}

- (BOOL)isTruncated {
    return _truncated;
}

- (uint64_t)unsupportedRulesCount {
    return _unsupportedRulesCount;
}

@end

@interface ABNetworkRequestResult ()

- (instancetype)initWithResult:(adblock_ffi::NetworkRequestResult)result;

@end

@implementation ABNetworkRequestResult {
    BOOL _matched;
    BOOL _important;
    NSString *_redirect;
    NSString *_rewrittenURL;
    NSString *_exception;
    NSString *_filter;
    NSString *_cspDirectives;
}

- (instancetype)initWithResult:(adblock_ffi::NetworkRequestResult)result {
    self = [super init];
    if (self) {
        _matched = result.matched;
        _important = result.important;
        _redirect = [ABNSStringFromRustString(result.redirect) copy];
        _rewrittenURL = [ABNSStringFromRustString(result.rewritten_url) copy];
        _exception = [ABNSStringFromRustString(result.exception) copy];
        _filter = [ABNSStringFromRustString(result.filter) copy];
        _cspDirectives = [ABNSStringFromRustString(result.csp_directives) copy];
    }
    return self;
}

- (BOOL)matched {
    return _matched;
}

- (BOOL)important {
    return _important;
}

- (NSString *)redirect {
    return _redirect;
}

- (NSString *)rewrittenURL {
    return _rewrittenURL;
}

- (NSString *)exception {
    return _exception;
}

- (NSString *)filter {
    return _filter;
}

- (NSString *)cspDirectives {
    return _cspDirectives;
}

@end

@implementation ABAdblockEngine {
    std::unique_ptr<rust::Box<adblock_ffi::Engine>> _engine;
}

- (instancetype)initWithFilterSet:(NSString *)filterSet {
    self = [super init];
    if (self) {
        _engine = std::make_unique<rust::Box<adblock_ffi::Engine>>(
            adblock_ffi::new_engine(ABRustStringFromNSString(filterSet)));
    }
    return self;
}

- (instancetype)initWithSerializedData:(NSData *)serializedData {
    self = [super init];
    if (self) {
        _engine = std::make_unique<rust::Box<adblock_ffi::Engine>>(
            adblock_ffi::new_engine_from_serialized(
                ABRustBytesFromNSData(serializedData)));
    }
    return self;
}

+ (ABContentBlockerRules *)contentBlockerRulesFromFilterSet:
    (NSString *)filterSet {
    return [self contentBlockerRulesFromFilterSet:filterSet ruleLimit:150000];
}

+ (ABContentBlockerRules *)contentBlockerRulesFromFilterSet:
    (NSString *)filterSet
                                              ruleLimit:(NSUInteger)ruleLimit {
    return [[ABContentBlockerRules alloc]
        initWithResult:adblock_ffi::content_blocker_rules(
                           ABRustStringFromNSString(filterSet),
                           static_cast<uint64_t>(ruleLimit))];
}

+ (NSString *)defaultResourcesJSON {
    return ABNSStringFromRustString(adblock_ffi::default_resources_json());
}

- (NSData *)serializedData {
    return ABNSDataFromRustBytes(adblock_ffi::engine_serialize(**_engine));
}

- (void)useResourcesJSON:(NSString *)json {
    adblock_ffi::engine_use_resources(**_engine,
                                      ABRustStringFromNSString(json));
}

- (NSString *)cosmeticResourcesForURL:(NSString *)url {
    return [self cosmeticResourcesForURL:url topFrame:YES];
}

- (NSString *)cosmeticResourcesForURL:(NSString *)url
                              topFrame:(BOOL)topFrame {
    rust::String result = adblock_ffi::engine_cosmetic_resources(
        **_engine, ABRustStringFromNSString(url), topFrame);
    return ABNSStringFromRustString(result);
}

- (ABNetworkRequestResult *)checkNetworkRequestWithURL:(NSString *)url
                                             sourceURL:(NSString *)sourceURL
                                           requestType:(NSString *)requestType {
    return [[ABNetworkRequestResult alloc]
        initWithResult:adblock_ffi::engine_check_network_request(
                           **_engine, ABRustStringFromNSString(url),
                           ABRustStringFromNSString(sourceURL),
                           ABRustStringFromNSString(requestType))];
}

- (NSString *)stylesheetForCosmeticRulesWithClasses:
                  (NSArray<NSString *> *)classes
                                                ids:(NSArray<NSString *> *)ids
                                     exceptionsJSON:(NSString *)exceptionsJSON {
    rust::String result = adblock_ffi::engine_stylesheet_for_cosmetic_rules(
        **_engine, ABRustStringVectorFromNSArray(classes),
        ABRustStringVectorFromNSArray(ids),
        ABRustStringFromNSString(exceptionsJSON));
    return ABNSStringFromRustString(result);
}

- (NSArray<NSString *> *)selectorsForCosmeticRulesWithClasses:
                  (NSArray<NSString *> *)classes
                                                ids:(NSArray<NSString *> *)ids
                                     exceptionsJSON:(NSString *)exceptionsJSON {
    rust::Vec<rust::String> result =
        adblock_ffi::engine_selectors_for_cosmetic_rules(
            **_engine, ABRustStringVectorFromNSArray(classes),
            ABRustStringVectorFromNSArray(ids),
            ABRustStringFromNSString(exceptionsJSON));
    return ABNSArrayFromRustStringVector(result);
}

@end
