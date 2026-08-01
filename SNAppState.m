#import "SNAppState.h"
#import <objc/message.h>
#import <UIKit/UIKit.h>
#import "SNRuntime.h"

static inline NSString *SN_CopyString(id any, NSString *fallback) {
    if (!any) return [[fallback copy] autorelease];
    if ([any isKindOfClass:NSString.class]) return [[(NSString *)any copy] autorelease];
    if (CFGetTypeID((__bridge CFTypeRef)any) == CFStringGetTypeID()) return [[(__bridge NSString *)any copy] autorelease];
    if ([any respondsToSelector:@selector(stringValue)]) {
        NSString *s = [any stringValue];
        return s ? [[s copy] autorelease] : [[fallback copy] autorelease];
    }
    return [[fallback copy] autorelease];
}

static NSString *SN_TryStrFromSelectors(id obj, NSArray<NSString *> *selectors) {
    for (NSString *name in selectors) {
        id v = SN_PerformNoArg(obj, name);
        NSString *s = SN_CopyString(v, @"");
        if (s.length) return s;
    }
    return @"";
}

// ----- SBApplicationController path -----
static id SN_SBApplicationControllerShared(void) {
    Class C = NSClassFromString(@"SBApplicationController");
    if (!C) return nil;
    return SN_PerformNoArg(C, @"sharedInstance");
}

static id SN_SBForegroundAppObject(void) {
    id ctrl = SN_SBApplicationControllerShared();
    if (!ctrl) return nil;

    for (NSString *selName in @[@"foregroundApplication", @"frontmostApplication", @"activeApplication", @"_foregroundApplication"]) {
        id app = SN_PerformNoArg(ctrl, selName);
        if (app) return app;
    }
    id fgSet = SN_PerformNoArg(ctrl, @"foregroundApplications");
    if (fgSet) {
        if ([fgSet respondsToSelector:@selector(anyObject)]) {
            id any = ((id (*)(id, SEL))objc_msgSend)(fgSet, @selector(anyObject));
            if (any) return any;
        } else if ([fgSet isKindOfClass:[NSArray class]]) {
            NSArray *arr = (NSArray *)fgSet;
            if (arr.count) return arr.firstObject;
        }
    }
    id all = SN_PerformNoArg(ctrl, @"allApplications");
    if ([all isKindOfClass:[NSArray class]]) {
        for (id app in (NSArray *)all) {
            for (NSString *flagSel in @[@"isForeground", @"isFrontmost", @"isActive"]) {
                BOOL b = NO;
                if (SN_PerformBoolNoArg(app, flagSel, &b) && b) return app;
            }
        }
    }
    return nil;
}

static NSString *SN_AppBundleID_FromAppObj(id app) {
    if (!app) return @"-";
    NSString *bid = SN_TryStrFromSelectors(app, @[@"bundleIdentifier", @"displayIdentifier", @"bundleID"]);
    return bid.length ? bid : @"-";
}

static NSString *SN_AppName_FromAppObj(id app) {
    if (!app) return @"-";
    NSString *nm = SN_TryStrFromSelectors(app, @[@"displayName", @"localizedName", @"name"]);
    if (nm.length) return nm;
    NSString *bid = SN_AppBundleID_FromAppObj(app);
    return bid.length ? bid : @"-";
}

// ----- FrontBoard path -----
static id SN_FBSharedLike(NSArray<NSString *> *classes, NSArray<NSString *> *getters) {
    for (NSString *clsName in classes) {
        Class C = NSClassFromString(clsName);
        if (!C) continue;
        for (NSString *g in getters) {
            id mgr = SN_PerformNoArg(C, g);
            if (mgr) return mgr;
        }
    }
    return nil;
}

static id SN_FBFrontmostProcessObj(void) {
    id mgr = SN_FBSharedLike(@[@"FBProcessManager", @"FBProcessManagerShared", @"FBSystemApp", @"FBSSystemService"],
                             @[@"sharedInstance", @"sharedManager"]);
    if (!mgr) return nil;

    for (NSString *selName in @[@"foregroundApplicationProcess", @"frontmostApplicationProcess", @"frontmostProcess", @"foregroundProcess", @"_foregroundApplicationProcess"]) {
        id proc = SN_PerformNoArg(mgr, selName);
        if (proc) return proc;
    }
    for (NSString *listSel in @[@"allApplicationProcesses", @"allProcesses", @"applicationProcesses"]) {
        id list = SN_PerformNoArg(mgr, listSel);
        if ([list isKindOfClass:[NSArray class]]) {
            for (id proc in (NSArray *)list) {
                for (NSString *flagSel in @[@"isForeground", @"isVisible", @"isFrontmost"]) {
                    BOOL b = NO;
                    if (SN_PerformBoolNoArg(proc, flagSel, &b) && b) return proc;
                }
            }
        }
    }
    return nil;
}

static NSString *SN_FBProcessBundleID(id proc) {
    if (!proc) return @"-";
    NSString *bid = SN_TryStrFromSelectors(proc, @[@"bundleIdentifier", @"bundleID", @"executableBundleIdentifier", @"bundleIdentifierIfAvailable"]);
    if (bid.length) return bid;
    id app = SN_PerformNoArg(proc, @"application");
    if (app) {
        NSString *a = SN_AppBundleID_FromAppObj(app);
        if (a.length) return a;
    }
    return @"-";
}

// ----- Accessibility last resort -----
static NSString *SN_AX_FrontMostBundleID(void) {
    Class H = NSClassFromString(@"AXSpringBoardServerHelper");
    id helper = nil;
    if (H) {
        helper = SN_PerformNoArg(H, @"sharedServerHelper");
        if (!helper) helper = SN_PerformNoArg(H, @"sharedInstance");
        if (!helper) helper = SN_PerformNoArg(H, @"sharedServerInstance");
    }
    if (helper) {
        // Try direct bundle identifier getters first (cheapest)
        NSString *bid = SN_TryStrFromSelectors(helper, @[@"frontMostApplicationBundleIdentifier",
                                                         @"_frontMostAppBundleIdentifier"]);
        if (bid.length) return bid;

        // Fallback: fetch app object and derive bundle id
        id app = SN_PerformNoArg(helper, @"frontMostApplication");
        if (!app) app = SN_PerformNoArg(helper, @"_frontMostApplication");
        if (app) {
            NSString *axBID = SN_AppBundleID_FromAppObj(app);
            if (axBID.length) return axBID;
        }
    }
    return @"-";
}

// ----- Public API (no logging) -----
NSString *SNAppStateTryForegroundBID(void) {
    @try {
        id sbApp = SN_SBForegroundAppObject();
        NSString *bid = SN_AppBundleID_FromAppObj(sbApp);
        if (bid.length && ![bid isEqualToString:@"-"]) return bid;

        id fbProc = SN_FBFrontmostProcessObj();
        bid = SN_FBProcessBundleID(fbProc);
        if (bid.length && ![bid isEqualToString:@"-"]) return bid;

        bid = SN_AX_FrontMostBundleID();
        if (bid.length && ![bid isEqualToString:@"-"]) return bid;

        return @"-";
    } @catch (...) {
        return @"-";
    }
}

NSString *SNAppStateTryForegroundName(void) {
    @try {
        id sbApp = SN_SBForegroundAppObject();
        NSString *name = SN_AppName_FromAppObj(sbApp);
        if (name.length && ![name isEqualToString:@"-"]) return name;

        id fbProc = SN_FBFrontmostProcessObj();
        if (fbProc) {
            NSString *nm = SN_TryStrFromSelectors(fbProc, @[@"displayName", @"name"]);
            if (nm.length) return nm;
            NSString *bid = SN_FBProcessBundleID(fbProc);
            if (bid.length) return bid;
        }

        NSString *bid = SN_AX_FrontMostBundleID();
        if (bid.length && ![bid isEqualToString:@"-"]) return bid;

        return @"-";
    } @catch (...) {
        return @"-";
    }
}
