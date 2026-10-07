#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSString *const kSPPrefsDomain = @"com.mody.safariplusultimate";
static NSString *const kSPPrefsPath = @"/var/mobile/Library/Preferences/com.mody.safariplusultimate.plist";
static NSString *const kSPGuardVersion = @"1.0.0-1";
static const NSInteger kSPCrashLimit = 3;
static const double kSPSurviveSeconds = 6.0;

static char kSPInstalledKey;

static id SP_RawPref(NSString *key) {
    id v = nil;
    @try {
        static NSUserDefaults *suite = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            suite = [[NSUserDefaults alloc] initWithSuiteName:kSPPrefsDomain];
        });
        v = [suite objectForKey:key];
        if (v) {
            return v;
        }
        CFPropertyListRef cf = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)kSPPrefsDomain);
        if (cf) {
            v = CFBridgingRelease(cf);
            return v;
        }
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kSPPrefsPath];
        v = d[key];
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
        NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:kSPPrefsDomain];
        id a1 = [suite objectForKey:@"forceCopy"];
        id a2 = [suite objectForKey:@"masterEnabled"];
        [s appendFormat:@"A suite: forceCopy=%@ master=%@\n", a1 ? a1 : @"nil", a2 ? a2 : @"nil"];

        CFPropertyListRef b1 = CFPreferencesCopyAppValue(CFSTR("forceCopy"), (__bridge CFStringRef)kSPPrefsDomain);
        NSString *b1s = b1 ? [NSString stringWithFormat:@"%@", (__bridge id)b1] : @"nil";
        if (b1) {
            CFRelease(b1);
        }
        [s appendFormat:@"B cfprefs: forceCopy=%@\n", b1s];

        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL ex = [fm fileExistsAtPath:kSPPrefsPath];
        BOOL rd = [fm isReadableFileAtPath:kSPPrefsPath];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kSPPrefsPath];
        [s appendFormat:@"C file: exists=%d readable=%d dict=%@\n", (int)ex, (int)rd, d ? d : @"nil"];

        NSError *err = nil;
        NSArray *items = [fm contentsOfDirectoryAtPath:@"/var/mobile/Library/Preferences" error:&err];
        NSMutableArray *hits = [NSMutableArray array];
        for (NSString *n in items) {
            if ([n rangeOfString:@"mody" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [hits addObject:n];
            }
        }
        NSString *errs = err ? [NSString stringWithFormat:@"%ld", (long)err.code] : @"none";
        [s appendFormat:@"D list: %@ err=%@\n", hits, errs];

        [s appendFormat:@"effective: forceCopy=%d master=%d\n",
         (int)SP_Pref(@"forceCopy", YES), (int)SP_Pref(@"masterEnabled", YES)];
        [s appendFormat:@"home=%@", NSHomeDirectory()];
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

        if (SP_Pref(@"forceCopy", YES)) {
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
        if (!SP_Pref(@"masterEnabled", YES)) {
            return;
        }
        %init(SPWebKit);
    }
}
