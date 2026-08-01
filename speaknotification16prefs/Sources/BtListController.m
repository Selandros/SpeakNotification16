#import "BtListController.h"
#import "SNPrefsUtil.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "SNPreferences.h"

@interface BtListController ()
@property (nonatomic, strong) NSMutableArray<NSString *> *items;
@end

@implementation BtListController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.navigationItem.title = @"Bluetooth Devices";
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

    PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"Trusted Bluetooth"
                                                        target:self
                                                           set:NULL
                                                           get:NULL
                                                        detail:Nil
                                                          cell:PSGroupCell
                                                          edit:Nil];
    [group setProperty:@"Add current device or enter manually. Swipe to delete."
                forKey:@"footerText"];
    [specs addObject:group];

    // Inline "Add current BT" button
    PSSpecifier *btn = [PSSpecifier preferenceSpecifierNamed:@"Add current BT"
                                                      target:self
                                                         set:NULL
                                                         get:NULL
                                                      detail:Nil
                                                        cell:PSButtonCell
                                                        edit:Nil];
    btn->action = @selector(addCurrentTapped);
    [specs addObject:btn];

    for (NSUInteger i = 0; i < self.items.count; i++) {
        NSString *name = self.items[i];
        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:name
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
    NSArray *arr = [defs objectForKey:kBTKey];
    if ([arr isKindOfClass:NSArray.class]) {
        self.items = [arr mutableCopy];
    } else {
        self.items = [NSMutableArray array];
    }
}

- (void)saveItems {
    NSUserDefaults *defs = [SNPrefsUtil suite];
    [defs setObject:self.items forKey:kBTKey];
    [defs synchronize];
    [SNPrefsUtil postPrefsChanged];
}

#pragma mark - Add

- (void)addTapped {
    [self promptForBTName:@""];
}

- (void)addCurrentTapped {
    NSString *dev = [self fetchCurrentBluetoothName] ?: @"";
    [self promptForBTName:dev];
}

- (void)promptForBTName:(NSString *)prefill {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Add Bluetooth device"
                                                                message:@"Enter the device name."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tf) {
        tf.placeholder = @"Device name";
        tf.text = prefill;
        tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *name = ac.textFields.firstObject.text ?: @"";
        if (name.length == 0) { return; }
        if (![weakSelf.items containsObject:name]) {
            [weakSelf.items addObject:name];
            [weakSelf saveItems];
            [weakSelf reloadSpecifiers];
        }
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

// Try to infer connected BT device via audio route (A2DP/HFP/LE). Fallback to nil.
- (NSString *)fetchCurrentBluetoothName {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    AVAudioSessionRouteDescription *route = [session currentRoute];
    for (AVAudioSessionPortDescription *out in route.outputs) {
        NSString *type = out.portType;
        if ([type isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
            [type isEqualToString:AVAudioSessionPortBluetoothHFP] ||
            [type isEqualToString:AVAudioSessionPortBluetoothLE]) {
            if (out.portName.length > 0) {
                return out.portName;
            }
        }
    }
    return nil;
}

#pragma mark - Table editing

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    // row 0 is the group, row 1 is the button; BT items start at row 2
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
