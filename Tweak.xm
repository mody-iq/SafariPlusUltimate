#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSString *const kSPGuardVersion = @"1.0.0-2";
static const NSInteger kSPCrashLimit = 3;
static const double kSPSurviveSeconds = 6.0;

static char kSPInstalledKey;

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

static NSString *SP_DebugText(void) {
    NSMutableString *s = [NSMutableString string];
    @try {
        id g1 = SP_GlobalVal(@"SPPlusMaster");
        id g2 = SP_GlobalVal(@"SPPlusForceCopy");
        [s appendFormat:@"G global: master=%@ force=%@\n", g1 ? g1 : @"nil", g2 ? g2 : @"nil"];

        NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
        id h1 = [std objectForKey:@"SPPlusMaster"];
        id h2 = [std objectForKey:@"SPPlusForceCopy"];
        [s appendFormat:@"H std: master=%@ force=%@\n", h1 ? h1 : @"nil", h2 ? h2 : @"nil"];

        [s appendFormat:@"effective: master=%d force=%d",
         (int)SP_Pref(@"SPPlusMaster", YES), (int)SP_Pref(@"SPPlusForceCopy", YES)];
    } @catch (NSException *e) {
        [s appendFormat:@"exception: %@", e];
    }
    return s;
}

static void SP_ShowDebugLater(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            UIWindow *keyWindow = nil;
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if ([sc isKindOfClass:[UIWindowScene class]]) {
                    for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                        if (w.isKeyWindow) {
                            keyWindow = w;
                        }
                    }
                }
            }
            UIViewController *vc = keyWindow.rootViewController;
            while (vc.presentedViewController) {
                vc = vc.presentedViewController;
            }
            if (!vc) {
                return;
            }
            UIAlertController *alert =
                [UIAlertController alertControllerWithTitle:@"SafariPlus Debug"
                                                    message:SP_DebugText()
                                             preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
            [vc presentViewController:alert animated:YES completion:nil];
        } @catch (NSException *e) {
        }
    });
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
        SP_ShowDebugLater();
        if (!SP_Pref(@"SPPlusMaster", YES)) {
            return;
        }
        %init(SPWebKit);
    }
}
