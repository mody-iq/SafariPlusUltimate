#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSString *const kSPGuardVersion = @"1.0.0-5";
static const NSInteger kSPCrashLimit = 3;
static const double kSPSurviveSeconds = 6.0;

static char kSPInstalledKey;

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
    @try {
        id ov = [[NSUserDefaults standardUserDefaults] objectForKey:@"SPDesktopOverride"];
        if ([ov respondsToSelector:@selector(boolValue)]) {
            return [ov boolValue];
        }
    } @catch (NSException *e) {
    }
    return SP_Pref(@"SPPlusDesktop", NO);
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

        if (SP_Pref(@"SPPlusForceCopy", YES)) {
            WKUserScript *script =
                [[WKUserScript alloc] initWithSource:SP_ForceCopyJS()
                                       injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                    forMainFrameOnly:NO];
            [ucc addUserScript:script];
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
    }
}
