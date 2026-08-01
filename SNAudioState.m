#import "SNAudioState.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/message.h>
#import "SNMixPolicy.h"
#import "SNRuntime.h"

BOOL SNIsPhoneMediaApp(NSString * _Nullable bundleID) {
    if (bundleID.length == 0) return NO;

    static NSArray<NSString *> *mediaApps = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mediaApps = @[
            @"com.apple.Music",
            @"com.apple.podcasts",
            @"com.spotify.client",
            @"fm.overcast.overcast",
            @"au.com.shiftyjelly.PocketCasts",
            @"com.google.ios.youtubemusic",
            @"com.audible.iphone",
            @"se.sr.srplay",
            @"com.tidalmusic.iOS",
            @"com.soundcloud.TouchApp",
            @"com.deezer.Deezer"
        ];
    });

    return [mediaApps containsObject:bundleID];
}

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

static inline id SN_Perform1(id obj, NSString *selName, id arg) {
    if (!obj || selName.length == 0) return nil;
    SEL sel = NSSelectorFromString(selName);
    if ([obj respondsToSelector:sel]) {
        return ((id (*)(id, SEL, id))objc_msgSend)(obj, sel, arg);
    }
    return nil;
}

static inline NSString *SN_TryNameSelectorsOn(id obj) {
    for (NSString *selName in @[@"displayName", @"localizedName", @"name", @"localizedShortName"]) {
        id v = SN_PerformNoArg(obj, selName);
        NSString *s = SN_CopyString(v, @"");
        if (s.length) return s;
    }
    return @"";
}

static inline NSString *SN_CurrentRouteName(void) {
    @try {
        AVAudioSession *sess = [AVAudioSession sharedInstance];
        AVAudioSessionRouteDescription *route = sess.currentRoute;
        if (!route) return @"-";
        AVAudioSessionPortDescription *out = route.outputs.firstObject;
        if (!out) return @"-";
        NSString *name = out.portName;
        return name.length ? [[name copy] autorelease] : @"-";
    } @catch (...) {
        return @"-";
    }
}

// ---- Now Playing bundle ID via private but guarded SBMediaController (proven working for you) ----
static inline NSString *SN_NowPlayingBundleID_PrivateSafe(void) {
    @try {
        Class SBMediaController = NSClassFromString(@"SBMediaController");
        if (!SBMediaController) return @"-";

        id mc = SN_PerformNoArg(SBMediaController, @"sharedInstance");
        if (!mc) return @"-";

        for (NSString *selName in @[@"nowPlayingApplicationBundleIdentifier", @"nowPlayingAppBundleIdentifier"]) {
            id bid = SN_PerformNoArg(mc, selName);
            NSString *ret = SN_CopyString(bid, @"-");
            if (ret.length && ![ret isEqualToString:@"-"]) return ret;
        }

        id app = nil;
        for (NSString *selName in @[@"nowPlayingApplication", @"nowPlayingApp"]) {
            app = SN_PerformNoArg(mc, selName);
            if (app) break;
        }
        if (!app) return @"-";

        for (NSString *selName in @[@"bundleIdentifier", @"displayIdentifier", @"bundleID"]) {
            id bid = SN_PerformNoArg(app, selName);
            NSString *ret = SN_CopyString(bid, @"-");
            if (ret.length && ![ret isEqualToString:@"-"]) return ret;
        }
    } @catch (...) {
    }
    return @"-";
}

// ---- Resolve human-friendly app name from bundle ID (defensive, no logging) ----
static inline NSString *SN_AppNameForBundleID(NSString *bid) {
    if (!bid.length || [bid isEqualToString:@"-"]) return @"-";
    @try {
        Class SBAppController = NSClassFromString(@"SBApplicationController");
        if (SBAppController) {
            id shared = SN_PerformNoArg(SBAppController, @"sharedInstance");
            if (shared) {
                id app = SN_Perform1(shared, @"applicationWithBundleIdentifier:", bid);
                NSString *n = SN_TryNameSelectorsOn(app);
                if (n.length) return n;
            }
        }
    } @catch (...) {}

    @try {
        Class LSWorkspace = NSClassFromString(@"LSApplicationWorkspace");
        if (LSWorkspace) {
            id ws = SN_PerformNoArg(LSWorkspace, @"defaultWorkspace");
            if (ws) {
                id proxy = SN_Perform1(ws, @"applicationForIdentifier:", bid);
                NSString *n = SN_TryNameSelectorsOn(proxy);
                if (n.length) return n;
            }
        }
    } @catch (...) {}

    return bid;
}

// Classify current output route into a cheap, policy-friendly enum.
// No logging here; pure motorics.
SNMixRouteKind SNClassifyCurrentRouteKind(void)
{
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        AVAudioSessionRouteDescription *r = s.currentRoute;
        AVAudioSessionPortDescription *out = r.outputs.firstObject;
        if (!out) return SNMixRouteUnknown;

        NSString *t = out.portType ?: @"";
        if ([t isEqualToString:AVAudioSessionPortCarAudio]) return SNMixRouteCarPlay;

        if ([t isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
            [t isEqualToString:AVAudioSessionPortBluetoothLE]   ||
            [t isEqualToString:AVAudioSessionPortBluetoothHFP]) {
            return SNMixRouteBluetooth;
        }

        if ([t isEqualToString:AVAudioSessionPortBuiltInSpeaker] ||
            [t isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
            return SNMixRouteSpeaker;
        }

        if ([t isEqualToString:AVAudioSessionPortAirPlay]) return SNMixRouteAirPlay;

        return SNMixRouteUnknown;
    } @catch (...) {
        return SNMixRouteUnknown;
    }
}

// ---- Public probe (no song/artist; only app-level info) ----
void SNAudioNowPlayingProbe(NSString **outBundleID,
                            NSString **outDisplayName,
                            BOOL *outIsPlaying,
                            NSString **outRouteName) {
    if (outBundleID) *outBundleID = @"-";
    if (outDisplayName) *outDisplayName = @"-";
    if (outIsPlaying) *outIsPlaying = NO;
    if (outRouteName) *outRouteName = @"-";

    @try {
        if (outRouteName) *outRouteName = SN_CurrentRouteName();

        BOOL playing = NO;
        @try {
            NSDictionary *np = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
            NSNumber *rate = np[MPNowPlayingInfoPropertyPlaybackRate];
            if (rate && [rate isKindOfClass:NSNumber.class]) {
                playing = (rate.doubleValue > 0.01);
            } else {
                playing = [[AVAudioSession sharedInstance] isOtherAudioPlaying];
            }
        } @catch (...) {
            @try { playing = [[AVAudioSession sharedInstance] isOtherAudioPlaying]; } @catch (...) { playing = NO; }
        }
        if (outIsPlaying) *outIsPlaying = playing;

        NSString *bid = SN_NowPlayingBundleID_PrivateSafe();
        if (outBundleID) *outBundleID = bid;

        NSString *name = SN_AppNameForBundleID(bid);
        if (outDisplayName) *outDisplayName = name.length ? name : (bid.length ? bid : @"-");
    } @catch (...) {
    }
}
