#import "WifiListController.h"
#import "SNPrefsUtil.h"
#import <Preferences/PSSpecifier.h>
#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>
#import "SNPreferences.h"

@interface WifiListController ()
@property (nonatomic, strong) NSMutableArray<NSString *> *items;
@end

@implementation WifiListController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.navigationItem.title = @"Wi-Fi Networks";
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                          target:self
                                                          action:@selector(addTapped)];
        self.navigationItem.leftBarButtonItem = self.editButtonItem;
        [self loadItems];
    }
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (_specifiers) { return _specifiers; }

    NSMutableArray *specs = [NSMutableArray array];

    PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"Trusted SSIDs"
                                                        target:self
                                                           set:NULL
                                                           get:NULL
                                                        detail:Nil
                                                          cell:PSGroupCell
                                                          edit:Nil];
    [group setProperty:@"Add current SSID or enter manually. Tap to delete."
                forKey:@"footerText"];
    [specs addObject:group];

    // Inline "Add current SSID" button (in addition to + in nav bar)
    PSSpecifier *btn = [PSSpecifier preferenceSpecifierNamed:@"Add current SSID"
                                                      target:self
                                                         set:NULL
                                                         get:NULL
                                                      detail:Nil
                                                        cell:PSButtonCell
                                                        edit:Nil];
    btn->action = @selector(addCurrentTapped);
    [specs addObject:btn];

    for (NSUInteger i = 0; i < self.items.count; i++) {
        NSString *ssid = self.items[i];
        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:ssid
                                                          target:self
                                                             set:NULL
                                                             get:NULL
                                                          detail:Nil
                                                            cell:PSTitleValueCell
                                                            edit:Nil];
        [row setProperty:@(i) forKey:@"index"];
        [specs addObject:row];
    }

    _specifiers = specs;
    return _specifiers;
}

#pragma mark - Data

- (void)loadItems {
    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSArray *arr = [defs objectForKey:kSSIDsKey];
    if ([arr isKindOfClass:NSArray.class]) {
        self.items = [arr mutableCopy];
    } else {
        self.items = [NSMutableArray array];
    }
}

- (void)saveItems {
    NSUserDefaults *defs = [SNPrefsUtil suite];
    [defs setObject:self.items forKey:kSSIDsKey];
    [defs synchronize];
    [SNPrefsUtil postPrefsChanged];
}

#pragma mark - Add

- (void)addTapped {
    [self promptForSSID:@""];
}

- (void)addCurrentTapped {
    NSString *ssid = [self fetchCurrentSSID] ?: @"";
    [self promptForSSID:ssid];
}

- (void)promptForSSID:(NSString *)prefill {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Add SSID"
                                                                message:@"Enter the Wi-Fi network name (SSID)."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tf) {
        tf.placeholder = @"SSID";
        tf.text = prefill;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *ssid = ac.textFields.firstObject.text ?: @"";
        if (ssid.length == 0) { return; }
        if (![weakSelf.items containsObject:ssid]) {
            [weakSelf.items addObject:ssid];
            [weakSelf saveItems];
            [weakSelf reloadSpecifiers];
        }
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

// --- MobileWiFi-based SSID fetch (iOS 16 friendly) ---
- (NSString *)fetchCurrentSSID {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
    if (!handle) return nil;

    typedef const struct __WiFiManagerClient * WiFiManagerClientRef;
    typedef const struct __WiFiDeviceClient  * WiFiDeviceClientRef;
    typedef const struct __WiFiNetwork       * WiFiNetworkRef;

    typedef WiFiManagerClientRef (*t_WiFiManagerClientCreate)(CFAllocatorRef, int);
    typedef CFArrayRef          (*t_WiFiManagerClientCopyDevices)(WiFiManagerClientRef);
    typedef WiFiNetworkRef      (*t_WiFiDeviceClientCopyCurrentNetwork)(WiFiDeviceClientRef);
    typedef CFStringRef         (*t_WiFiNetworkGetSSID)(WiFiNetworkRef);

    t_WiFiManagerClientCreate pCreate = (t_WiFiManagerClientCreate)dlsym(handle, "WiFiManagerClientCreate");
    t_WiFiManagerClientCopyDevices pCopyDevices = (t_WiFiManagerClientCopyDevices)dlsym(handle, "WiFiManagerClientCopyDevices");
    t_WiFiDeviceClientCopyCurrentNetwork pCopyCurrent = (t_WiFiDeviceClientCopyCurrentNetwork)dlsym(handle, "WiFiDeviceClientCopyCurrentNetwork");
    t_WiFiNetworkGetSSID pGetSSID = (t_WiFiNetworkGetSSID)dlsym(handle, "WiFiNetworkGetSSID");

    if (!pCreate || !pCopyDevices || !pCopyCurrent || !pGetSSID) {
        dlclose(handle);
        return nil;
    }

    NSString *result = nil;
    WiFiManagerClientRef mgr = pCreate(kCFAllocatorDefault, 0);
    if (mgr) {
        CFArrayRef devices = pCopyDevices(mgr);
        if (devices && CFArrayGetCount(devices) > 0) {
            WiFiDeviceClientRef dev = (WiFiDeviceClientRef)CFArrayGetValueAtIndex(devices, 0);
            if (dev) {
                WiFiNetworkRef net = pCopyCurrent(dev);
                if (net) {
                    CFStringRef ssid = pGetSSID(net);
                    if (ssid) result = [(__bridge_transfer NSString *)ssid copy];
                    CFRelease(net);
                }
            }
        }
        if (devices) CFRelease(devices);
    }

    dlclose(handle);
    return result.length ? result : nil;
}

#pragma mark - Table editing

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    // row 0 is the group, row 1 is the button; SSIDs start at row 2
    return indexPath.row > 1;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete && indexPath.row > 1) {
        NSUInteger idx = indexPath.row - 2;
        if (idx < self.items.count) {
            [self.items removeObjectAtIndex:idx];
            [self saveItems];
            [self reloadSpecifiers];
        }
    }
}

@end
