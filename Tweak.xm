#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSString *const kSPGuardVersion = @"1.0.0-9";
static const NSInteger kSPCrashLimit = 3;
static const double kSPSurviveSeconds = 6.0;

static NSString *const kSPAdsURL = @"https://lists.angelakismax.com/ads.json";
static NSString *const kSPPrivacyURL = @"https://lists.angelakismax.com/privacy.json";
static NSString *const kSPCookiesURL = @"https://lists.angelakismax.com/cookies.json";
static const double kSPListMaxAge = 72.0 * 3600.0;
static const double kSPListRetryAfterFail = 6.0 * 3600.0;
static const double kSPDownloadDelay = 8.0;

static char kSPInstalledKey;
static char kSPAttachedKey;

typedef void (^SPDecisionHandler)(WKNavigationActionPolicy, WKWebpagePreferences *);

static id SP_GlobalVal(NSString *key) {
    CFPropertyListRef cf = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    kCFPreferencesAnyApplication);
    if (!cf) {
        return nil;
    }
    return CFBridgingRelease(cf);
}

static id SP_RawPref(NSString *key) {
    id v = nil;
    @try {
        v = SP_GlobalVal(key);
        if (v) {
            return v;
        }
        v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    } @catch (NSException *e) {
    }
    return v;
}

static BOOL SP_Pref(NSString *key, BOOL def) {
    id v = SP_RawPref(key);
    if ([v respondsToSelector:@selector(boolValue)]) {
        return [v boolValue];
    }
    return def;
}

static BOOL SP_GuardBegin(void) {
    @try {
        NSUserDefaults *std = [NSUserDefaults standardUserDefaults];

        NSString *savedVersion = [std stringForKey:@"SPGuardVersion"];
        if (![savedVersion isEqualToString:kSPGuardVersion]) {
            [std setObject:kSPGuardVersion forKey:@"SPGuardVersion"];
            [std setInteger:0 forKey:@"SPCrashCount"];
            [std setBool:NO forKey:@"SPTripped"];
            [std setBool:NO forKey:@"SPPending"];
            [std setInteger:0 forKey:@"SPAdCrash"];
            [std setBool:NO forKey:@"SPAdTripped"];
            [std setBool:NO forKey:@"SPAdPending"];
        }

        if ([std boolForKey:@"SPTripped"]) {
            [std synchronize];
            return NO;
        }

        if ([std boolForKey:@"SPPending"]) {
            NSInteger count = [std integerForKey:@"SPCrashCount"] + 1;
            [std setInteger:count forKey:@"SPCrashCount"];
            if (count >= kSPCrashLimit) {
                [std setBool:YES forKey:@"SPTripped"];
                [std setBool:NO forKey:@"SPPending"];
                [std synchronize];
                return NO;
            }
        }

        [std setBool:YES forKey:@"SPPending"];
        [std synchronize];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPSurviveSeconds * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSUserDefaults *s = [NSUserDefaults standardUserDefaults];
            [s setBool:NO forKey:@"SPPending"];
            [s setInteger:0 forKey:@"SPCrashCount"];
            [s synchronize];
        });
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

static BOOL SP_DesktopEffective(void) {
    BOOL settingsVal = SP_Pref(@"SPPlusDesktop", NO);
    @try {
        NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
        id ov = [std objectForKey:@"SPDesktopOverride"];
        if ([ov isKindOfClass:[NSDictionary class]]) {
            id val = ov[@"val"];
            id base = ov[@"base"];
            if ([val respondsToSelector:@selector(boolValue)] &&
                [base respondsToSelector:@selector(boolValue)] &&
                ([base boolValue] == settingsVal)) {
                return [val boolValue];
            }
            [std removeObjectForKey:@"SPDesktopOverride"];
        } else if (ov) {
            [std removeObjectForKey:@"SPDesktopOverride"];
        }
    } @catch (NSException *e) {
    }
    return settingsVal;
}

static void SP_PatchDelegateClass(Class cls) {
    if (!cls) {
        return;
    }
    static NSMutableSet *done = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        done = [NSMutableSet set];
    });
    NSString *name = NSStringFromClass(cls);
    @synchronized (done) {
        if ([done containsObject:name]) {
            return;
        }
        [done addObject:name];
    }

    SEL sel = @selector(webView:decidePolicyForNavigationAction:preferences:decisionHandler:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        return;
    }
    IMP orig = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    if (!orig || !types) {
        return;
    }

    IMP newImp = imp_implementationWithBlock(
        ^(id self_, WKWebView *wv, WKNavigationAction *action, WKWebpagePreferences *prefs,
          SPDecisionHandler handler) {
            BOOL should = NO;
            @try {
                BOOL isMain = (!action.targetFrame || action.targetFrame.isMainFrame);
                NSString *scheme = [action.request.URL.scheme lowercaseString];
                BOOL web = ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]);
                should = (isMain && web && SP_DesktopEffective());
            } @catch (NSException *e) {
                should = NO;
            }

            SPDecisionHandler wrapped = handler;
            if (should && handler) {
                wrapped = ^(WKNavigationActionPolicy policy, WKWebpagePreferences *pp) {
                    WKWebpagePreferences *use = pp;
                    if (!use) {
                        use = prefs;
                    }
                    if (!use) {
                        use = [[WKWebpagePreferences alloc] init];
                    }
                    use.preferredContentMode = WKContentModeDesktop;
                    handler(policy, use);
                };
            }

            ((void (*)(id, SEL, WKWebView *, WKNavigationAction *, WKWebpagePreferences *,
                       SPDecisionHandler))orig)(self_, sel, wv, action, prefs, wrapped);
        });
    class_replaceMethod(cls, sel, newImp, types);
}

#pragma mark - Popup guard

static NSArray *SP_PopupAllowHosts(void) {
    return @[@"accounts.google.com", @"appleid.apple.com", @"login.microsoftonline.com",
             @"login.live.com", @"facebook.com", @"github.com", @"paypal.com", @"stripe.com",
             @"twitter.com", @"x.com", @"discord.com", @"linkedin.com", @"auth0.com",
             @"okta.com"];
}

static BOOL SP_HostInList(NSString *host, NSArray *list) {
    if (host.length == 0) {
        return NO;
    }
    for (NSString *e in list) {
        if ([host isEqualToString:e] || [host hasSuffix:[@"." stringByAppendingString:e]]) {
            return YES;
        }
    }
    return NO;
}

static NSString *SP_BaseDomain(NSString *host) {
    NSArray *p = [host componentsSeparatedByString:@"."];
    if (p.count <= 2) {
        return host;
    }
    NSString *last = p[p.count - 1];
    NSString *sec = p[p.count - 2];
    NSSet *slds = [NSSet setWithObjects:@"co", @"com", @"org", @"net", @"gov", @"edu", @"ac", nil];
    if (last.length == 2 && [slds containsObject:sec]) {
        return [[p subarrayWithRange:NSMakeRange(p.count - 3, 3)] componentsJoinedByString:@"."];
    }
    return [[p subarrayWithRange:NSMakeRange(p.count - 2, 2)] componentsJoinedByString:@"."];
}

static BOOL SP_ShouldBlockPopup(WKWebView *opener, WKNavigationAction *action) {
    @try {
        if (!SP_Pref(@"SPPlusPopupGuard", YES)) {
            return NO;
        }
        NSString *host = [action.request.URL.host lowercaseString];
        if (host.length > 0 && SP_HostInList(host, SP_PopupAllowHosts())) {
            return NO;
        }
        WKNavigationType type = action.navigationType;
        if (type == WKNavigationTypeLinkActivated) {
            if (!SP_Pref(@"SPPlusPopupStrict", NO)) {
                return NO;
            }
            NSString *pageHost = [opener.URL.host lowercaseString];
            if (host.length == 0 || pageHost.length == 0) {
                return NO;
            }
            return ![SP_BaseDomain(host) isEqualToString:SP_BaseDomain(pageHost)];
        }
        if (type == WKNavigationTypeOther) {
            return YES;
        }
    } @catch (NSException *e) {
    }
    return NO;
}

static void SP_PatchUIDelegateClass(Class cls) {
    if (!cls) {
        return;
    }
    static NSMutableSet *done = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        done = [NSMutableSet set];
    });
    NSString *name = NSStringFromClass(cls);
    @synchronized (done) {
        if ([done containsObject:name]) {
            return;
        }
        [done addObject:name];
    }

    SEL sel = @selector(webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        return;
    }
    IMP orig = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    if (!orig || !types) {
        return;
    }

    IMP newImp = imp_implementationWithBlock(
        ^id(id self_, WKWebView *wv, WKWebViewConfiguration *cfg, WKNavigationAction *action,
            WKWindowFeatures *feat) {
            if (SP_ShouldBlockPopup(wv, action)) {
                return nil;
            }
            return ((id (*)(id, SEL, WKWebView *, WKWebViewConfiguration *, WKNavigationAction *,
                            WKWindowFeatures *))orig)(self_, sel, wv, cfg, action, feat);
        });
    class_replaceMethod(cls, sel, newImp, types);
}

static NSString *SP_PopupGuardJS(void) {
    static const char *js = R"SPPG(
(function () {
  try {
    if (window.__spPopupGuard) { return; }
    window.__spPopupGuard = true;

    var ALLOW = __SP_ALLOW__;

    function hostOf(u) {
      try { return new URL(u, location.href).hostname.toLowerCase(); } catch (e) { return ''; }
    }
    function inAllow(h) {
      for (var i = 0; i < ALLOW.length; i++) {
        var a = ALLOW[i];
        if (h === a || h.slice(-(a.length + 1)) === '.' + a) { return true; }
      }
      return false;
    }
    var SLD = { co: 1, com: 1, org: 1, net: 1, gov: 1, edu: 1, ac: 1 };
    function base(h) {
      var p = h.split('.');
      if (p.length <= 2) { return h; }
      var last = p[p.length - 1];
      var sec = p[p.length - 2];
      if (last.length === 2 && SLD[sec]) { return p.slice(-3).join('.'); }
      return p.slice(-2).join('.');
    }

    var inCrossFrame = false;
    try { void window.top.location.href; } catch (e) { inCrossFrame = true; }
    var myBase = base((location.hostname || '').toLowerCase());

    function allowedOpen(url) {
      var h = hostOf(url || '');
      if (!h) { return false; }
      if (inAllow(h)) { return true; }
      if (inCrossFrame) { return false; }
      return base(h) === myBase;
    }

    function blockAnchor(a) {
      try {
        var href = a.href;
        if (!href || href.indexOf('http') !== 0) { return false; }
        var t = (a.target || '').toLowerCase();
        if (!t || t === '_self' || t === '_top' || t === '_parent') { return false; }
        if (a.hasAttribute('download')) { return false; }
        var h = hostOf(href);
        if (!h || inAllow(h)) { return false; }
        if (inCrossFrame) { return true; }
        return base(h) !== myBase;
      } catch (e) { return false; }
    }

    function decoy() {
      var loc = {};
      try {
        Object.defineProperty(loc, 'href', { get: function () { return 'about:blank'; }, set: function () {} });
      } catch (e) {}
      loc.assign = function () {};
      loc.replace = function () {};
      return {
        closed: false,
        opener: null,
        name: '',
        location: loc,
        focus: function () {},
        blur: function () {},
        close: function () { this.closed = true; },
        postMessage: function () {},
        document: {
          write: function () {},
          writeln: function () {},
          open: function () {},
          close: function () {},
          body: {},
          documentElement: {}
        }
      };
    }

    var nativeOpen = window.open;
    window.open = function (url, target, features) {
      try {
        if (!allowedOpen(url)) { return decoy(); }
      } catch (e) {}
      return nativeOpen.apply(window, arguments);
    };

    var nativeClick = HTMLElement.prototype.click;
    HTMLElement.prototype.click = function () {
      try {
        if (this instanceof HTMLAnchorElement && blockAnchor(this)) { return; }
      } catch (e) {}
      return nativeClick.apply(this, arguments);
    };

    var nativeDispatch = EventTarget.prototype.dispatchEvent;
    EventTarget.prototype.dispatchEvent = function (ev) {
      try {
        if (ev && ev.type === 'click' && this instanceof HTMLAnchorElement && blockAnchor(this)) {
          return false;
        }
      } catch (e) {}
      return nativeDispatch.apply(this, arguments);
    };

    window.addEventListener('click', function (e) {
      try {
        if (e.isTrusted === false) {
          var n = e.target;
          var a = (n && n.closest) ? n.closest('a') : null;
          if (a && blockAnchor(a)) {
            e.preventDefault();
            e.stopImmediatePropagation();
          }
        }
      } catch (err) {}
    }, true);
  } catch (e) {}
})();
)SPPG";
    NSString *tpl = [NSString stringWithUTF8String:js];
    NSData *d = [NSJSONSerialization dataWithJSONObject:SP_PopupAllowHosts() options:0 error:nil];
    NSString *arr = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"[]";
    return [tpl stringByReplacingOccurrencesOfString:@"__SP_ALLOW__" withString:arr];
}

#pragma mark - Ad blocking engine

static NSHashTable *SP_TrackedUccs(void) {
    static NSHashTable *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = [NSHashTable weakObjectsHashTable];
    });
    return t;
}

static NSMutableDictionary *SP_ActiveLists(void) {
    static NSMutableDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [NSMutableDictionary dictionary];
    });
    return d;
}

static void SP_AttachOne(WKUserContentController *ucc, NSString *ident, WKContentRuleList *list) {
    if (!ucc || !list || !ident) {
        return;
    }
    @try {
        NSMutableDictionary *att = objc_getAssociatedObject(ucc, &kSPAttachedKey);
        if (!att) {
            att = [NSMutableDictionary dictionary];
            objc_setAssociatedObject(ucc, &kSPAttachedKey, att, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        WKContentRuleList *old = att[ident];
        if (old == list) {
            return;
        }
        if (old) {
            [ucc removeContentRuleList:old];
        }
        [ucc addContentRuleList:list];
        att[ident] = list;
    } @catch (NSException *e) {
    }
}

static void SP_AttachAll(WKUserContentController *ucc) {
    NSDictionary *snap = [SP_ActiveLists() copy];
    for (NSString *k in snap) {
        SP_AttachOne(ucc, k, snap[k]);
    }
}

static void SP_ListReady(NSString *ident, WKContentRuleList *list) {
    if (!ident || !list) {
        return;
    }
    SP_ActiveLists()[ident] = list;
    for (WKUserContentController *u in [SP_TrackedUccs() allObjects]) {
        SP_AttachOne(u, ident, list);
    }
}

static BOOL SP_AdRemoteAllowed(void) {
    @try {
        NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
        if ([std boolForKey:@"SPAdTripped"]) {
            return NO;
        }
        if ([std boolForKey:@"SPAdPending"]) {
            NSInteger n = [std integerForKey:@"SPAdCrash"] + 1;
            [std setInteger:n forKey:@"SPAdCrash"];
            [std setBool:NO forKey:@"SPAdPending"];
            if (n >= 2) {
                [std setBool:YES forKey:@"SPAdTripped"];
                [std synchronize];
                return NO;
            }
            [std synchronize];
        }
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

static void SP_AdPendingBegin(void) {
    @try {
        NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
        [std setBool:YES forKey:@"SPAdPending"];
        [std synchronize];
    } @catch (NSException *e) {
    }
}

static void SP_AdPendingEnd(void) {
    @try {
        NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
        [std setBool:NO forKey:@"SPAdPending"];
        [std setInteger:0 forKey:@"SPAdCrash"];
        [std synchronize];
    } @catch (NSException *e) {
    }
}

static NSArray *SP_CoreAdDomains(void) {
    return @[@"doubleclick.net", @"googlesyndication.com", @"googleadservices.com",
             @"adservice.google.com", @"adnxs.com", @"adsrvr.org", @"advertising.com",
             @"taboola.com", @"outbrain.com", @"criteo.com", @"criteo.net", @"pubmatic.com",
             @"rubiconproject.com", @"openx.net", @"casalemedia.com", @"smartadserver.com",
             @"amazon-adsystem.com", @"moatads.com", @"adform.net", @"2mdn.net",
             @"serving-sys.com", @"mgid.com", @"revcontent.com", @"popads.net", @"popcash.net",
             @"propellerads.com", @"exoclick.com", @"juicyads.com", @"trafficjunky.net",
             @"adsterra.com", @"onclickads.net", @"clickadu.com", @"hilltopads.net", @"zedo.com",
             @"yieldmo.com", @"teads.tv", @"sharethrough.com", @"media.net", @"bidswitch.net",
             @"33across.com", @"lijit.com", @"sovrn.com", @"contextweb.com", @"adcolony.com",
             @"applovin.com", @"inmobi.com", @"mopub.com", @"vungle.com", @"chartboost.com",
             @"ironsrc.com", @"supersonicads.com"];
}

static NSArray *SP_CoreAdSelectors(void) {
    return @[@"ins.adsbygoogle", @".adsbygoogle", @"[id^=\"google_ads_iframe\"]",
             @"[id^=\"div-gpt-ad\"]", @"[data-ad-slot]", @"[data-google-query-id]",
             @".google-auto-placed", @"iframe[src*=\"doubleclick.net\"]",
             @"iframe[src*=\"googlesyndication.com\"]", @"[id^=\"taboola-\"]", @".OUTBRAIN",
             @".trc_rbox_container"];
}

static NSArray *SP_CoreTrackerDomains(void) {
    return @[@"google-analytics.com", @"analytics.google.com", @"scorecardresearch.com",
             @"quantserve.com", @"hotjar.com", @"hotjar.io", @"mixpanel.com", @"segment.io",
             @"amplitude.com", @"fullstory.com", @"mouseflow.com", @"crazyegg.com",
             @"chartbeat.com", @"chartbeat.net", @"clarity.ms", @"bat.bing.com",
             @"px.ads.linkedin.com", @"snap.licdn.com", @"analytics.tiktok.com",
             @"ads-twitter.com", @"analytics.twitter.com", @"omtrdc.net", @"demdex.net",
             @"krxd.net", @"bluekai.com", @"nr-data.net"];
}

static NSString *SP_BuildCoreJSON(NSArray *domains, NSArray *selectors) {
    NSMutableArray *rules = [NSMutableArray array];
    for (NSString *d in domains) {
        NSString *esc = [d stringByReplacingOccurrencesOfString:@"." withString:@"\\."];
        NSString *flt = [NSString stringWithFormat:@"^[^:]+:(//)?([^/]+\\.)?%@[:/]", esc];
        [rules addObject:@{@"trigger": @{@"url-filter": flt, @"load-type": @[@"third-party"]},
                           @"action": @{@"type": @"block"}}];
    }
    if (selectors.count > 0) {
        [rules addObject:@{@"trigger": @{@"url-filter": @".*"},
                           @"action": @{@"type": @"css-display-none",
                                        @"selector": [selectors componentsJoinedByString:@", "]}}];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:rules options:0 error:nil];
    if (!data) {
        return nil;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static void SP_LoadCore(NSString *ident, NSArray *domains, NSArray *selectors) {
    WKContentRuleListStore *store = [WKContentRuleListStore defaultStore];
    [store lookUpContentRuleListForIdentifier:ident
                            completionHandler:^(WKContentRuleList *list, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (list) {
                SP_ListReady(ident, list);
                return;
            }
            NSString *json = SP_BuildCoreJSON(domains, selectors);
            if (!json) {
                return;
            }
            [store compileContentRuleListForIdentifier:ident
                                encodedContentRuleList:json
                                     completionHandler:^(WKContentRuleList *l, NSError *e) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (l) {
                        SP_ListReady(ident, l);
                    }
                });
            }];
        });
    }];
}

static void SP_Download(NSString *ident, NSString *urlStr, void (^done)(void)) {
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (done) {
            done();
        }
        return;
    }
    NSMutableURLRequest *req =
        [NSMutableURLRequest requestWithURL:url
                                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                            timeoutInterval:90.0];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger code = [response isKindOfClass:[NSHTTPURLResponse class]]
                             ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *json = nil;
        if (!error && code == 200 && data.length > 2000 && data.length < 60u * 1024u * 1024u) {
            json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
            NSString *failKey = [@"SPListFail_" stringByAppendingString:ident];
            NSString *timeKey = [@"SPListTime_" stringByAppendingString:ident];
            double now = [[NSDate date] timeIntervalSince1970];

            BOOL valid = NO;
            if (json.length > 2000) {
                NSMutableCharacterSet *skip =
                    [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
                [skip addCharactersInString:@"\uFEFF"];
                NSString *head = [[json substringToIndex:MIN((NSUInteger)16, json.length)]
                                  stringByTrimmingCharactersInSet:skip];
                valid = [head hasPrefix:@"["];
            }
            if (!valid) {
                [std setDouble:now forKey:failKey];
                [std synchronize];
                if (done) {
                    done();
                }
                return;
            }

            [[WKContentRuleListStore defaultStore]
                compileContentRuleListForIdentifier:ident
                             encodedContentRuleList:json
                                  completionHandler:^(WKContentRuleList *list, NSError *err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSUserDefaults *s = [NSUserDefaults standardUserDefaults];
                    double t = [[NSDate date] timeIntervalSince1970];
                    if (list) {
                        SP_ListReady(ident, list);
                        [s setDouble:t forKey:timeKey];
                        [s removeObjectForKey:failKey];
                    } else {
                        [s setDouble:t forKey:failKey];
                    }
                    [s synchronize];
                    if (done) {
                        done();
                    }
                });
            }];
        });
    }];
    [task resume];
}

static NSMutableArray *gSPJobs = nil;
static BOOL gSPJobRunning = NO;

static void SP_RunNextJob(void) {
    if (gSPJobs.count == 0) {
        gSPJobRunning = NO;
        SP_AdPendingEnd();
        return;
    }
    gSPJobRunning = YES;
    SP_AdPendingBegin();
    NSArray *job = gSPJobs.firstObject;
    [gSPJobs removeObjectAtIndex:0];
    SP_Download(job[0], job[1], ^{
        SP_RunNextJob();
    });
}

static void SP_EnqueueDownload(NSString *ident, NSString *url) {
    if (!gSPJobs) {
        gSPJobs = [NSMutableArray array];
    }
    [gSPJobs addObject:@[ident, url]];
    if (!gSPJobRunning) {
        SP_RunNextJob();
    }
}

static void SP_LoadRemote(NSString *ident, NSString *urlStr, BOOL allowDownload) {
    WKContentRuleListStore *store = [WKContentRuleListStore defaultStore];
    [store lookUpContentRuleListForIdentifier:ident
                            completionHandler:^(WKContentRuleList *list, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (list) {
                SP_ListReady(ident, list);
            }
            if (!allowDownload) {
                return;
            }
            NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
            double now = [[NSDate date] timeIntervalSince1970];
            double last = [std doubleForKey:[@"SPListTime_" stringByAppendingString:ident]];
            double fail = [std doubleForKey:[@"SPListFail_" stringByAppendingString:ident]];
            BOOL stale = (!list) || ((now - last) > kSPListMaxAge);
            BOOL cooling = (fail > 0.0 && (now - fail) < kSPListRetryAfterFail);
            if (stale && !cooling) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPDownloadDelay * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    SP_EnqueueDownload(ident, urlStr);
                });
            }
        });
    }];
}

static void SP_AdblockStart(void) {
    BOOL ads = SP_Pref(@"SPPlusAdblock", YES);
    BOOL trk = SP_Pref(@"SPPlusTrackers", YES);
    BOOL cky = SP_Pref(@"SPPlusCookies", YES);
    if (!ads && !trk && !cky) {
        return;
    }
    BOOL remoteOK = SP_AdRemoteAllowed();

    if (ads) {
        SP_LoadCore(@"SPCoreAds1", SP_CoreAdDomains(), SP_CoreAdSelectors());
        SP_LoadRemote(@"SPAds", kSPAdsURL, remoteOK);
    }
    if (trk) {
        SP_LoadCore(@"SPCoreTrk1", SP_CoreTrackerDomains(), @[]);
        SP_LoadRemote(@"SPPrivacy", kSPPrivacyURL, remoteOK);
    }
    if (cky) {
        SP_LoadRemote(@"SPCookies", kSPCookiesURL, remoteOK);
    }
}

#pragma mark - Bridge and scripts

static double SP_Clamp01(double v) {
    if (v < 0.0) {
        return 0.0;
    }
    if (v > 1.0) {
        return 1.0;
    }
    return v;
}

@interface SPBridge : NSObject <WKScriptMessageHandlerWithReply>
@end

@implementation SPBridge

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
                 replyHandler:(void (^)(id _Nullable reply, NSString *_Nullable errorMessage))replyHandler {
    BOOL replied = NO;
    @try {
        if (!message.frameInfo.isMainFrame) {
            replied = YES;
            replyHandler(nil, @"main frame only");
            return;
        }
        NSDictionary *body = [message.body isKindOfClass:[NSDictionary class]] ? message.body : nil;
        id cmdObj = body[@"cmd"];
        NSString *cmd = [cmdObj isKindOfClass:[NSString class]] ? cmdObj : @"";
        NSUserDefaults *std = [NSUserDefaults standardUserDefaults];

        if ([cmd isEqualToString:@"getState"]) {
            NSMutableDictionary *r = [NSMutableDictionary dictionary];
            r[@"desktop"] = @(SP_DesktopEffective());
            id p = [std objectForKey:@"SPFabPos"];
            if ([p isKindOfClass:[NSDictionary class]]) {
                id fx = p[@"fx"];
                id fy = p[@"fy"];
                if ([fx respondsToSelector:@selector(doubleValue)] &&
                    [fy respondsToSelector:@selector(doubleValue)]) {
                    r[@"fx"] = @(SP_Clamp01([fx doubleValue]));
                    r[@"fy"] = @(SP_Clamp01([fy doubleValue]));
                }
            }
            replied = YES;
            replyHandler(r, nil);
            return;
        }

        if ([cmd isEqualToString:@"setPos"]) {
            id fxo = body[@"fx"];
            id fyo = body[@"fy"];
            double fx = [fxo respondsToSelector:@selector(doubleValue)] ? [fxo doubleValue] : 1.0;
            double fy = [fyo respondsToSelector:@selector(doubleValue)] ? [fyo doubleValue] : 0.62;
            [std setObject:@{@"fx": @(SP_Clamp01(fx)), @"fy": @(SP_Clamp01(fy))} forKey:@"SPFabPos"];
            [std synchronize];
            replied = YES;
            replyHandler(@{@"ok": @YES}, nil);
            return;
        }

        if ([cmd isEqualToString:@"toggleDesktop"]) {
            BOOL now = !SP_DesktopEffective();
            BOOL base = SP_Pref(@"SPPlusDesktop", NO);
            [std setObject:@{@"val": @(now), @"base": @(base)} forKey:@"SPDesktopOverride"];
            [std synchronize];

            replied = YES;
            replyHandler(@{@"desktop": @(now)}, nil);

            __weak WKWebView *wv = message.webView;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [wv reload];
            });
            return;
        }

        replied = YES;
        replyHandler(nil, @"unknown command");
    } @catch (NSException *e) {
        if (!replied) {
            replyHandler(nil, @"error");
        }
    }
}

@end

static NSString *SP_ForceCopyJS(void) {
    static const char *js = R"SPJS(
(function () {
  if (window.__spForceCopy) { return; }
  window.__spForceCopy = true;

  var css = '*,*::before,*::after{-webkit-user-select:text !important;user-select:text !important;-webkit-touch-callout:default !important;}';

  function injectStyle() {
    try {
      var s = document.createElement('style');
      s.setAttribute('data-sp', 'forcecopy');
      s.textContent = css;
      (document.head || document.documentElement).appendChild(s);
    } catch (e) {}
  }
  injectStyle();

  var evts = ['copy', 'cut', 'contextmenu', 'selectstart', 'dragstart'];
  evts.forEach(function (n) {
    window.addEventListener(n, function (e) { e.stopImmediatePropagation(); }, true);
  });

  var attrs = ['oncopy', 'oncut', 'oncontextmenu', 'onselectstart', 'ondragstart'];

  function clean(el) {
    try {
      attrs.forEach(function (a) {
        if (el && el.hasAttribute && el.hasAttribute(a)) { el.removeAttribute(a); }
      });
    } catch (e) {}
  }

  function cleanAll() {
    try {
      clean(document.documentElement);
      if (document.body) { clean(document.body); }
      attrs.forEach(function (a) { document[a] = null; });
      var list = document.querySelectorAll('[oncopy],[oncut],[oncontextmenu],[onselectstart],[ondragstart]');
      for (var i = 0; i < list.length; i++) { clean(list[i]); }
    } catch (e) {}
  }
  cleanAll();

  var timer = null;
  function schedule() {
    if (timer) { return; }
    timer = setTimeout(function () { timer = null; cleanAll(); }, 300);
  }

  document.addEventListener('DOMContentLoaded', function () { injectStyle(); cleanAll(); });
  window.addEventListener('load', cleanAll);

  try {
    new MutationObserver(schedule).observe(document.documentElement, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: attrs
    });
  } catch (e) {}
})();
)SPJS";
    return [NSString stringWithUTF8String:js];
}

static NSString *SP_FloatJS(void) {
    static const char *js = R"SPUI(
(function () {
  try {
    if (window.top !== window) { return; }
    if (window.__spPlusUI) { return; }
    window.__spPlusUI = true;

    var handlers = window.webkit && window.webkit.messageHandlers;
    var bridge = handlers && handlers.spBridge;
    if (!bridge) { return; }
    if (!document.documentElement) { return; }

    var FAB = 40;
    var pos = { fx: 1, fy: 0.62 };

    function el(tag, id, text) {
      var e = document.createElement(tag);
      if (id) { e.id = id; }
      if (text !== undefined) { e.textContent = text; }
      return e;
    }

    var host = document.createElement('div');
    host.style.cssText = 'all:initial;position:fixed;left:0;top:0;width:0;height:0;z-index:2147483647;';
    var root = host.attachShadow({ mode: 'closed' });

    var style = document.createElement('style');
    style.textContent = [
      '#box{position:fixed;left:0;top:0;width:40px;height:40px;transform-origin:0 0;direction:rtl;font-family:-apple-system,Helvetica,Arial,sans-serif;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;}',
      '#fab{width:40px;height:40px;border-radius:20px;background:rgba(28,28,30,0.55);border:1px solid rgba(255,255,255,0.28);color:#fff;font-size:20px;line-height:40px;text-align:center;cursor:pointer;touch-action:none;-webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px);}',
      '#panel{position:absolute;right:0;bottom:48px;width:210px;padding:10px;border-radius:16px;background:rgba(28,28,30,0.96);color:#fff;display:none;box-shadow:0 6px 24px rgba(0,0,0,0.35);}',
      '#title{font-size:13px;opacity:0.7;margin-bottom:8px;text-align:right;}',
      '#desk{display:flex;align-items:center;justify-content:space-between;width:100%;box-sizing:border-box;padding:10px 12px;border:0;border-radius:12px;background:rgba(255,255,255,0.12);color:#fff;font-size:15px;font-family:inherit;cursor:pointer;}',
      '#st{font-weight:600;color:#aaa;}',
      '#desk.on #st{color:#30d158;}',
      '#mode{margin-top:8px;font-size:12px;opacity:0.75;text-align:right;}'
    ].join('');

    var box = el('div', 'box');
    var panel = el('div', 'panel');
    panel.appendChild(el('div', 'title', '\u0633\u0641\u0627\u0631\u064A \u0628\u0644\u0633 \u0623\u0644\u062A\u064A\u0645\u064A\u062A'));
    var desk = el('button', 'desk');
    var lbl = el('span', 'lbl', '\u0648\u0636\u0639 \u0633\u0637\u062D \u0627\u0644\u0645\u0643\u062A\u0628');
    var st = el('span', 'st', '...');
    desk.appendChild(lbl);
    desk.appendChild(st);
    panel.appendChild(desk);
    var mode = el('div', 'mode', '');
    panel.appendChild(mode);
    var fab = el('div', 'fab', '\u2699\uFE0E');
    box.appendChild(panel);
    box.appendChild(fab);
    root.appendChild(style);
    root.appendChild(box);

    var busy = false;

    function clamp01(v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

    function metrics() {
      var vv = window.visualViewport;
      if (vv) {
        return { s: 1 / (vv.scale || 1), ox: vv.offsetLeft, oy: vv.offsetTop, w: vv.width, h: vv.height };
      }
      return { s: 1, ox: 0, oy: 0, w: window.innerWidth, h: window.innerHeight };
    }

    function updateMode() {
      var d = /Macintosh|X11|Windows NT/.test(navigator.userAgent || '');
      mode.textContent = '\u0627\u0644\u0639\u0631\u0636 \u0627\u0644\u062D\u0627\u0644\u064A: ' +
        (d ? '\u0633\u0637\u062D \u0627\u0644\u0645\u0643\u062A\u0628' : '\u062C\u0648\u0627\u0644');
    }

    function place() {
      var m = metrics();
      var size = FAB * m.s;
      var margin = 6 * m.s;
      var x = m.ox + margin + pos.fx * Math.max(0, m.w - size - 2 * margin);
      var y = m.oy + margin + pos.fy * Math.max(0, m.h - size - 2 * margin);
      box.style.transform = 'translate(' + x + 'px,' + y + 'px) scale(' + m.s + ')';
      if (pos.fx < 0.5) {
        panel.style.left = '0';
        panel.style.right = 'auto';
      } else {
        panel.style.right = '0';
        panel.style.left = 'auto';
      }
      if (pos.fy < 0.3) {
        panel.style.top = '48px';
        panel.style.bottom = 'auto';
      } else {
        panel.style.bottom = '48px';
        panel.style.top = 'auto';
      }
    }

    function setState(on) {
      desk.className = on ? 'on' : '';
      st.textContent = on ? '\u0645\u0641\u0639\u0651\u0644' : '\u0645\u062A\u0648\u0642\u0641';
    }

    function refresh() {
      updateMode();
      try {
        bridge.postMessage({ cmd: 'getState' }).then(function (r) {
          if (r && typeof r.desktop === 'boolean') { setState(r.desktop); }
          if (r && typeof r.fx === 'number' && typeof r.fy === 'number') {
            pos.fx = clamp01(r.fx);
            pos.fy = clamp01(r.fy);
            place();
          }
        }, function () {});
      } catch (e) {}
    }

    function savePos() {
      try {
        bridge.postMessage({ cmd: 'setPos', fx: pos.fx, fy: pos.fy }).then(function () {}, function () {});
      } catch (e) {}
    }

    desk.addEventListener('click', function (ev) {
      ev.preventDefault();
      ev.stopPropagation();
      if (busy) { return; }
      busy = true;
      st.textContent = '...';
      try {
        bridge.postMessage({ cmd: 'toggleDesktop' }).then(function (r) {
          if (r && typeof r.desktop === 'boolean') { setState(r.desktop); }
        }, function () { busy = false; refresh(); });
      } catch (e) { busy = false; }
    }, false);

    fab.addEventListener('click', function (ev) {
      ev.preventDefault();
      ev.stopPropagation();
      var open = (panel.style.display === 'block');
      panel.style.display = open ? 'none' : 'block';
      if (!open) { refresh(); }
    }, false);

    var dragging = false;
    var moved = false;
    var sx = 0;
    var sy = 0;
    var sfx = 0;
    var sfy = 0;

    fab.addEventListener('touchstart', function (ev) {
      if (!ev.touches || ev.touches.length !== 1) { return; }
      var t = ev.touches[0];
      dragging = true;
      moved = false;
      sx = t.clientX;
      sy = t.clientY;
      sfx = pos.fx;
      sfy = pos.fy;
    }, { passive: true });

    fab.addEventListener('touchmove', function (ev) {
      if (!dragging || !ev.touches || ev.touches.length !== 1) { return; }
      var t = ev.touches[0];
      var dx = t.clientX - sx;
      var dy = t.clientY - sy;
      if (!moved && (Math.abs(dx) + Math.abs(dy)) > 8) {
        moved = true;
        panel.style.display = 'none';
      }
      if (moved) {
        ev.preventDefault();
        var m = metrics();
        var size = FAB * m.s;
        var margin = 6 * m.s;
        pos.fx = clamp01(sfx + dx / Math.max(1, m.w - size - 2 * margin));
        pos.fy = clamp01(sfy + dy / Math.max(1, m.h - size - 2 * margin));
        place();
      }
    }, { passive: false });

    fab.addEventListener('touchend', function (ev) {
      if (!dragging) { return; }
      dragging = false;
      if (moved) {
        ev.preventDefault();
        pos.fx = pos.fx < 0.5 ? 0 : 1;
        place();
        savePos();
        moved = false;
      }
    }, { passive: false });

    fab.addEventListener('touchcancel', function () {
      dragging = false;
      moved = false;
    }, { passive: true });

    document.addEventListener('click', function (ev) {
      try {
        var path = ev.composedPath ? ev.composedPath() : [];
        if (path.indexOf(host) === -1) { panel.style.display = 'none'; }
      } catch (e) {}
    }, true);

    var pending = false;
    function schedule() {
      if (pending) { return; }
      pending = true;
      requestAnimationFrame(function () {
        pending = false;
        place();
      });
    }

    if (window.visualViewport) {
      window.visualViewport.addEventListener('resize', schedule);
      window.visualViewport.addEventListener('scroll', schedule);
    }
    window.addEventListener('scroll', schedule, { passive: true });
    window.addEventListener('resize', schedule);
    window.addEventListener('orientationchange', schedule);
    window.addEventListener('load', function () {
      if (!host.isConnected && document.documentElement) { document.documentElement.appendChild(host); }
      place();
    });

    document.documentElement.appendChild(host);
    place();
    setTimeout(place, 400);
    refresh();
  } catch (e) {}
})();
)SPUI";
    return [NSString stringWithUTF8String:js];
}

static void SP_InstallScripts(WKWebView *wv) {
    @try {
        WKUserContentController *ucc = wv.configuration.userContentController;
        if (!ucc) {
            return;
        }
        if (objc_getAssociatedObject(ucc, &kSPInstalledKey)) {
            return;
        }
        objc_setAssociatedObject(ucc, &kSPInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        [SP_TrackedUccs() addObject:ucc];
        SP_AttachAll(ucc);

        if (SP_Pref(@"SPPlusPopupGuard", YES)) {
            WKUserScript *guard =
                [[WKUserScript alloc] initWithSource:SP_PopupGuardJS()
                                       injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                    forMainFrameOnly:NO];
            [ucc addUserScript:guard];
        }

        if (SP_Pref(@"SPPlusForceCopy", YES)) {
            WKUserScript *script =
                [[WKUserScript alloc] initWithSource:SP_ForceCopyJS()
                                       injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                    forMainFrameOnly:NO];
            [ucc addUserScript:script];
        }

        if (SP_Pref(@"SPPlusFloatBtn", NO)) {
            WKContentWorld *world = [WKContentWorld worldWithName:@"SPPlus"];
            SPBridge *bridge = [[SPBridge alloc] init];
            [ucc addScriptMessageHandlerWithReply:bridge contentWorld:world name:@"spBridge"];
            WKUserScript *ui =
                [[WKUserScript alloc] initWithSource:SP_FloatJS()
                                       injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                    forMainFrameOnly:YES
                                      inContentWorld:world];
            [ucc addUserScript:ui];
        }
    } @catch (NSException *e) {
    }
}

%group SPWebKit

%hook WKWebView

- (id)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    id r = %orig;
    if (r) {
        SP_InstallScripts((WKWebView *)r);
    }
    return r;
}

- (void)setNavigationDelegate:(id<WKNavigationDelegate>)delegate {
    %orig;
    if (delegate) {
        SP_PatchDelegateClass([(NSObject *)delegate class]);
    }
}

- (void)setUIDelegate:(id<WKUIDelegate>)delegate {
    %orig;
    if (delegate) {
        SP_PatchUIDelegateClass([(NSObject *)delegate class]);
    }
}

%end

%end

%ctor {
    @autoreleasepool {
        if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"MobileSafari"]) {
            return;
        }
        if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){16, 0, 0}]) {
            return;
        }
        if (!objc_getClass("WKWebView")) {
            return;
        }
        if (!SP_GuardBegin()) {
            return;
        }
        if (!SP_Pref(@"SPPlusMaster", YES)) {
            return;
        }
        %init(SPWebKit);
        dispatch_async(dispatch_get_main_queue(), ^{
            SP_AdblockStart();
        });
    }
}
