#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "SNAppListProvider.h"
#import "SNPrefsUtil.h"
#import "SNSharedKeys.h"

@interface SNUnknownNumberExcludedAppsController : PSListController
@end

@implementation SNUnknownNumberExcludedAppsController

- (NSArray *)specifiers
{
    if (_specifiers) return _specifiers;

    NSMutableArray *items = [NSMutableArray array];
    PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"EXCLUDED APPS"
                                                            target:self
                                                               set:NULL
                                                               get:NULL
                                                            detail:nil
                                                              cell:PSGroupCell
                                                              edit:nil];
    [group setProperty:@"Selected apps bypass Ignore Unknown Numbers and continue through normal SpeakNotification rules."
                forKey:@"footerText"];
    [items addObject:group];

    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSArray *stored = [defs objectForKey:kSNUnknownNumberExcludedAppsKey];
    NSSet *excluded = [stored isKindOfClass:NSArray.class] ? [NSSet setWithArray:stored] : [NSSet set];
    for (NSDictionary *app in SNVisibleAppListForceRefresh()) {
        NSString *bundle = app[@"bundle"];
        NSString *name = app[@"name"];
        if (bundle.length == 0 || name.length == 0) continue;

        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:name
                                                              target:self
                                                                 set:@selector(setExcluded:specifier:)
                                                                 get:@selector(isExcluded:)
                                                              detail:nil
                                                                cell:PSSwitchCell
                                                                edit:nil];
        [row setProperty:bundle forKey:@"bundleID"];
        [row setProperty:@( [excluded containsObject:bundle] ) forKey:@"default"];
        [items addObject:row];
    }

    _specifiers = [items mutableCopy];
    return _specifiers;
}

- (id)isExcluded:(PSSpecifier *)specifier
{
    NSArray *stored = [[SNPrefsUtil suite] objectForKey:kSNUnknownNumberExcludedAppsKey];
    return @([stored isKindOfClass:NSArray.class] && [stored containsObject:[specifier propertyForKey:@"bundleID"]]);
}

- (void)setExcluded:(id)value specifier:(PSSpecifier *)specifier
{
    NSString *bundle = [specifier propertyForKey:@"bundleID"];
    if (bundle.length == 0) return;

    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSetWithArray:[defs objectForKey:kSNUnknownNumberExcludedAppsKey] ?: @[]];
    if ([value boolValue]) {
        [set addObject:bundle];
    } else {
        [set removeObject:bundle];
    }
    [defs setObject:set.array forKey:kSNUnknownNumberExcludedAppsKey];
    [defs synchronize];
    [SNPrefsUtil postPrefsChanged];
}

@end
