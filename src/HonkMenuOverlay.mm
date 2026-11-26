#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <cmath>
#include <cstdint>
#include <cstring>

#include "HonkFeatureState.hpp"

// Coordinates are documented practice destinations from the local upstream
// behavior reference. The source code and artwork are not copied.
typedef struct { const char *label; float x, y, z; } HonkTeleportPreset;
static const HonkTeleportPreset kPresets[] = {
    {"Starting area", -45.5f, 0.4f, -29.6f}, {"Statue / bench", -19.8f, 0.3f, -13.4f},
    {"Garden", -7.6f, 0.8f, -16.4f}, {"High street", 21.2f, 0.9f, -11.8f},
    {"Back gardens", 16.1f, 0.9f, 6.5f}, {"Pink house", 6.2f, 1.3f, 21.8f},
    {"Pub", -23.3f, 1.3f, 2.2f}, {"Mini village", -49.2f, 0.8f, 5.9f},
    {"Geesus clip", -24.9f, -0.2f, -9.7f}, {"Pub clip", -26.8f, 0.5f, -5.1f},
    {"Blink clip", -35.5f, 1.3f, 4.2f}, {"Tower climb", -54.1f, 1.6f, 1.5f},
    {"Bridge clip", -2.6f, 0.1f, 4.8f}, {"House clip", 0.4f, 1.5f, 16.7f},
    {"Above pub", -37.2f, 10.3f, 8.0f}, {"Back garden skybox", 16.1f, 5.7f, 7.2f},
    {"Above well", -5.2f, 10.7f, -5.2f}, {"Above pink house", 9.6f, 7.8f, 18.4f},
    {"Picnic outskirts", -34.1f, 0.9f, -32.9f}, {"Behind bell pit", -51.2f, -0.1f, -37.0f},
    {"Far mini village", -43.4f, 1.3f, 22.2f}, {"Map threshold", -40.7f, 10.7f, -10.2f},
    {"Above bell pit", -49.6f, 3.9f, -37.0f},
};

static const uint8_t kHonkGameUUID[16] = {
    0x8c, 0x9e, 0x46, 0x8f, 0x0d, 0x54, 0x39, 0xe5,
    0x86, 0x4f, 0x17, 0x64, 0x91, 0x60, 0x76, 0x98,
};
static const uintptr_t kHonkStateVA = 0x102e1b000ULL;
static GooseJumpData *gHonkState;
static UIView *gHonkRoot;
static UIView *gHonkPanel;
static UIButton *gHonkLauncher;
static UIStackView *gHonkContent;
static UIScrollView *gHonkScroll;
static UILabel *gHonkImpulseValue;
static UILabel *gHonkSpeedValue;
static NSTimer *gHonkRefresh;
static NSInteger gSelectedPage = 0;

@interface HonkPassthroughView : UIView
@end

@interface HonkMenuOverlay : NSObject
+ (void)installWhenReady;
+ (void)refresh;
+ (void)settingChanged:(id)sender;
+ (void)menuAction:(id)sender;
+ (void)selectPage:(id)sender;
+ (void)lifecycleEnded:(NSNotification *)notification;
@end

@implementation HonkPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
@end

static void HonkResolveGuest(void) {
    if (gHonkState) return;
    const uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) continue;
        const struct mach_header_64 *h64 = (const struct mach_header_64 *)header;
        const struct load_command *cmd = (const struct load_command *)(h64 + 1);
        for (uint32_t c = 0; c < h64->ncmds; ++c) {
            if (cmd->cmdsize < sizeof(struct load_command)) break;
            if (cmd->cmd == LC_UUID && cmd->cmdsize >= sizeof(struct uuid_command)) {
                const struct uuid_command *uuid = (const struct uuid_command *)cmd;
                if (std::memcmp(uuid->uuid, kHonkGameUUID, sizeof(kHonkGameUUID)) == 0) {
                    gHonkState = (GooseJumpData *)((uintptr_t)_dyld_get_image_vmaddr_slide(i) + kHonkStateVA);
                    return;
                }
            }
            cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
        }
    }
}

static UIWindow *HonkGameWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    id delegate = app.delegate;
    if (!delegate || [NSStringFromClass([delegate class]) rangeOfString:@"UnityAppController"].location == NSNotFound)
        return nil;
    SEL selector = NSSelectorFromString(@"window");
    if (![delegate respondsToSelector:selector]) return nil;
    return ((UIWindow *(*)(id, SEL))objc_msgSend)(delegate, selector);
}

static UIButton *HonkButton(NSString *title, NSInteger tag, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = tag;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(9, 12, 9, 12);
    configuration.baseForegroundColor = UIColor.whiteColor;
    configuration.background.backgroundColor = [UIColor colorWithWhite:0.14 alpha:0.94];
    configuration.background.cornerRadius = 11;
    button.configuration = configuration;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    button.multipleTouchEnabled = YES;
    button.exclusiveTouch = NO;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

static UILabel *HonkLabel(NSString *text, UIFontWeight weight, CGFloat size, UIColor *color) {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

static void HonkAddRow(UIStackView *stack, UIView *view) {
    [stack addArrangedSubview:view];
    [view.heightAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;
}

static UISlider *HonkSlider(UIStackView *stack, NSString *title, float min, float max,
                            float value, NSInteger tag) {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisVertical;
    row.spacing = 5;
    UILabel *label = HonkLabel(title, UIFontWeightSemibold, 14, UIColor.whiteColor);
    UILabel *valueLabel = HonkLabel(@"", UIFontWeightRegular, 13, UIColor.systemTealColor);
    UISlider *slider = [[UISlider alloc] init];
    slider.minimumValue = min;
    slider.maximumValue = max;
    slider.value = value;
    slider.tag = tag;
    slider.multipleTouchEnabled = YES;
    slider.exclusiveTouch = NO;
    [slider addTarget:[NSClassFromString(@"HonkMenuOverlay") class]
               action:@selector(settingChanged:) forControlEvents:UIControlEventValueChanged];
    [row addArrangedSubview:label];
    [row addArrangedSubview:slider];
    valueLabel.text = tag == 2 ? [NSString stringWithFormat:@"%.1f units/s", value]
                              : [NSString stringWithFormat:@"%.0f%%", value * 100.0f];
    [row addArrangedSubview:valueLabel];
    HonkAddRow(stack, row);
    if (tag == 2) gHonkImpulseValue = valueLabel;
    if (tag == 3) gHonkSpeedValue = valueLabel;
    return slider;
}

static void HonkClearContent(void) {
    for (UIView *view in [gHonkContent.arrangedSubviews copy]) {
        [gHonkContent removeArrangedSubview:view];
        [view removeFromSuperview];
    }
}

static void HonkAddUnavailable(NSString *title, NSString *reason) {
    UIStackView *card = [[UIStackView alloc] init];
    card.axis = UILayoutConstraintAxisVertical;
    card.spacing = 4;
    UILabel *name = HonkLabel(title, UIFontWeightSemibold, 15, UIColor.whiteColor);
    UILabel *detail = HonkLabel([NSString stringWithFormat:@"Unavailable in this build — %@", reason],
                                UIFontWeightRegular, 12, UIColor.systemOrangeColor);
    [card addArrangedSubview:name];
    [card addArrangedSubview:detail];
    HonkAddRow(gHonkContent, card);
}

static float HonkReadJumpImpulse(void) {
    if (!gHonkState) return 2.5f;
    auto *bits = reinterpret_cast<volatile uint32_t *>(&gHonkState->jumpImpulse);
    return GooseJumpInput::bitsFloat(__atomic_load_n(bits, __ATOMIC_ACQUIRE));
}

static void HonkBuildMovementPage(void) {
    UISwitch *enabled = [[UISwitch alloc] init];
    enabled.tag = 1;
    enabled.on = HonkFeatures::jumpEnabled(gHonkState);
    [enabled addTarget:[NSClassFromString(@"HonkMenuOverlay") class]
                action:@selector(settingChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *jumpRow = [[UIStackView alloc] init];
    jumpRow.axis = UILayoutConstraintAxisHorizontal;
    jumpRow.alignment = UIStackViewAlignmentCenter;
    jumpRow.distribution = UIStackViewDistributionEqualSpacing;
    [jumpRow addArrangedSubview:HonkLabel(@"Jump modification", UIFontWeightSemibold, 15, UIColor.whiteColor)];
    [jumpRow addArrangedSubview:enabled];
    HonkAddRow(gHonkContent, jumpRow);

    HonkSlider(gHonkContent, @"Jump impulse", HonkFeatures::kMinimumJumpImpulse,
               HonkFeatures::kMaximumJumpImpulse, HonkReadJumpImpulse(), 2);
    HonkSlider(gHonkContent, @"Horizontal speed", HonkFeatures::kMinimumSpeedFactor,
               HonkFeatures::kMaximumSpeedFactor, HonkFeatures::speedFactor(gHonkState), 3);
    UIButton *save = HonkButton(@"Save goose position", 1, [NSClassFromString(@"HonkMenuOverlay") class], @selector(menuAction:));
    UIButton *restore = HonkButton(@"Restore saved position", 2, [NSClassFromString(@"HonkMenuOverlay") class], @selector(menuAction:));
    HonkAddRow(gHonkContent, save);
    HonkAddRow(gHonkContent, restore);
    HonkAddUnavailable(@"Noclip / floating", @"safe goose-collider enumeration and restoration are not yet verified");
}

static void HonkBuildTeleportPage(void) {
    HonkAddRow(gHonkContent, HonkLabel(@"Area and practice locations", UIFontWeightBold, 17, UIColor.systemTealColor));
    HonkAddRow(gHonkContent, HonkLabel(@"Moves the goose through Rigidbody.MovePosition on the physics hook. Out-of-bounds targets may disrupt play; use the original game restart to recover.", UIFontWeightRegular, 12, UIColor.lightTextColor));
    for (NSUInteger i = 0; i < sizeof(kPresets) / sizeof(kPresets[0]); ++i) {
        const NSString *title = [NSString stringWithUTF8String:kPresets[i].label];
        UIButton *button = HonkButton([NSString stringWithFormat:@"%@   ›", title], 100 + (NSInteger)i,
                                     [NSClassFromString(@"HonkMenuOverlay") class], @selector(menuAction:));
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        HonkAddRow(gHonkContent, button);
    }
}

static void HonkBuildPage(NSInteger page) {
    HonkClearContent();
    switch (page) {
        case 0: HonkBuildMovementPage(); break;
        case 1: HonkBuildTeleportPage(); break;
        case 2:
            HonkAddUnavailable(@"First-person camera", @"camera rig and goose camera lifecycle need a verified native mapping");
            HonkAddUnavailable(@"Magic / free camera", @"creating and managing Unity cameras from native code is not implemented");
            HonkAddUnavailable(@"Teleport goose to camera", @"depends on the unavailable free-camera feature");
            break;
        case 3:
            HonkAddUnavailable(@"Disable shoo / NPC tracking", @"NPC brain objects and safe per-scene state restoration are not mapped");
            HonkAddUnavailable(@"NPC resize / manipulation", @"NPC transforms and original state capture are not verified");
            break;
        case 4:
            HonkAddUnavailable(@"Item teleport / spawning", @"scene object identity and ownership are not mapped");
            HonkAddUnavailable(@"Task completion", @"progression state has not been mapped; unsafe to modify");
            HonkAddUnavailable(@"Collider visualization", @"render-thread drawing integration is not implemented");
            break;
        case 5:
            HonkAddUnavailable(@"Cloning / experimental tools", @"Unity object creation and destruction APIs are not integrated");
            break;
    }
    [gHonkScroll setContentOffset:CGPointZero animated:NO];
}

@implementation HonkMenuOverlay

+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{ [self installWhenReady]; });
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(lifecycleEnded:) name:UIApplicationWillResignActiveNotification object:nil];
    [center addObserver:self selector:@selector(lifecycleEnded:) name:UIApplicationDidEnterBackgroundNotification object:nil];
}

+ (void)installWhenReady {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self installWhenReady]; });
        return;
    }
    HonkResolveGuest();
    UIWindow *window = HonkGameWindow();
    UIView *root = window.rootViewController.view;
    if (!window || !root || !gHonkState) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self installWhenReady]; });
        return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSNumber *jumpPreference = [defaults objectForKey:@"HonkMenu.JumpEnabled"];
    NSNumber *impulsePreference = [defaults objectForKey:@"HonkMenu.JumpImpulse"];
    NSNumber *speedPreference = [defaults objectForKey:@"HonkMenu.SpeedFactor"];
    HonkFeatures::setJumpEnabled(gHonkState, jumpPreference ? jumpPreference.boolValue : true);
    HonkFeatures::setJumpImpulse(gHonkState, impulsePreference ? impulsePreference.floatValue : HonkReadJumpImpulse());
    HonkFeatures::setSpeedFactor(gHonkState, speedPreference ? speedPreference.floatValue : 1.0f);

    if (gHonkRoot && gHonkRoot.superview == root) {
        [self refresh];
        return;
    }
    [gHonkRoot removeFromSuperview];
    gHonkRoot = [[HonkPassthroughView alloc] initWithFrame:CGRectZero];
    gHonkRoot.translatesAutoresizingMaskIntoConstraints = NO;
    gHonkRoot.multipleTouchEnabled = YES;
    gHonkRoot.exclusiveTouch = NO;
    [root addSubview:gHonkRoot];
    [NSLayoutConstraint activateConstraints:@[
        [gHonkRoot.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [gHonkRoot.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [gHonkRoot.topAnchor constraintEqualToAnchor:root.topAnchor],
        [gHonkRoot.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];

    gHonkLauncher = HonkButton(@"HM", 0, self, @selector(menuAction:));
    gHonkLauncher.accessibilityLabel = @"Open Honk Menu";
    gHonkLauncher.backgroundColor = [UIColor colorWithRed:0.02 green:0.35 blue:0.38 alpha:0.92];
    gHonkLauncher.layer.cornerRadius = 19;
    [gHonkRoot addSubview:gHonkLauncher];
    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [gHonkLauncher.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:14],
        [gHonkLauncher.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [gHonkLauncher.widthAnchor constraintEqualToConstant:52],
        [gHonkLauncher.heightAnchor constraintEqualToConstant:40],
    ]];

    gHonkPanel = [[UIView alloc] initWithFrame:CGRectZero];
    gHonkPanel.translatesAutoresizingMaskIntoConstraints = NO;
    gHonkPanel.hidden = YES;
    gHonkPanel.backgroundColor = [UIColor colorWithWhite:0.035 alpha:0.96];
    gHonkPanel.layer.cornerRadius = 18;
    gHonkPanel.layer.borderColor = [UIColor colorWithRed:0.15 green:0.74 blue:0.75 alpha:0.65].CGColor;
    gHonkPanel.layer.borderWidth = 1.2;
    gHonkPanel.clipsToBounds = YES;
    gHonkPanel.multipleTouchEnabled = YES;
    gHonkPanel.exclusiveTouch = NO;
    [gHonkRoot addSubview:gHonkPanel];
    NSLayoutConstraint *panelWidth = [gHonkPanel.widthAnchor constraintEqualToConstant:360];
    panelWidth.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *panelHeight = [gHonkPanel.heightAnchor constraintEqualToConstant:520];
    panelHeight.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [gHonkPanel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [gHonkPanel.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        panelWidth,
        [gHonkPanel.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-20],
        panelHeight,
        [gHonkPanel.heightAnchor constraintLessThanOrEqualToAnchor:safe.heightAnchor constant:-20],
    ]];

    UIStackView *outer = [[UIStackView alloc] init];
    outer.translatesAutoresizingMaskIntoConstraints = NO;
    outer.axis = UILayoutConstraintAxisVertical;
    outer.spacing = 10;
    outer.layoutMargins = UIEdgeInsetsMake(14, 14, 12, 14);
    outer.layoutMarginsRelativeArrangement = YES;
    [gHonkPanel addSubview:outer];
    [NSLayoutConstraint activateConstraints:@[
        [outer.leadingAnchor constraintEqualToAnchor:gHonkPanel.leadingAnchor],
        [outer.trailingAnchor constraintEqualToAnchor:gHonkPanel.trailingAnchor],
        [outer.topAnchor constraintEqualToAnchor:gHonkPanel.topAnchor],
        [outer.bottomAnchor constraintEqualToAnchor:gHonkPanel.bottomAnchor],
    ]];
    UIStackView *top = [[UIStackView alloc] init];
    top.axis = UILayoutConstraintAxisHorizontal;
    top.alignment = UIStackViewAlignmentCenter;
    top.distribution = UIStackViewDistributionEqualSpacing;
    [top addArrangedSubview:HonkLabel(@"HONK MENU · iOS", UIFontWeightHeavy, 17, UIColor.systemTealColor)];
    [top addArrangedSubview:HonkButton(@"Close", -1, self, @selector(menuAction:))];
    [outer addArrangedSubview:top];

    UIScrollView *tabs = [[UIScrollView alloc] init];
    tabs.translatesAutoresizingMaskIntoConstraints = NO;
    tabs.showsHorizontalScrollIndicator = NO;
    tabs.alwaysBounceHorizontal = YES;
    UIStackView *tabStack = [[UIStackView alloc] init];
    tabStack.axis = UILayoutConstraintAxisHorizontal;
    tabStack.spacing = 6;
    tabStack.translatesAutoresizingMaskIntoConstraints = NO;
    NSArray *pages = @[@"Move", @"Teleport", @"Camera", @"Goose/NPC", @"World", @"Experimental"];
    for (NSInteger i = 0; i < (NSInteger)pages.count; ++i)
        [tabStack addArrangedSubview:HonkButton(pages[i], 10 + i, self, @selector(selectPage:))];
    [tabs addSubview:tabStack];
    [NSLayoutConstraint activateConstraints:@[
        [tabStack.leadingAnchor constraintEqualToAnchor:tabs.contentLayoutGuide.leadingAnchor],
        [tabStack.trailingAnchor constraintEqualToAnchor:tabs.contentLayoutGuide.trailingAnchor],
        [tabStack.topAnchor constraintEqualToAnchor:tabs.contentLayoutGuide.topAnchor],
        [tabStack.bottomAnchor constraintEqualToAnchor:tabs.contentLayoutGuide.bottomAnchor],
        [tabStack.heightAnchor constraintEqualToAnchor:tabs.frameLayoutGuide.heightAnchor],
    ]];
    [outer addArrangedSubview:tabs];
    [tabs.heightAnchor constraintEqualToConstant:43].active = YES;

    gHonkScroll = [[UIScrollView alloc] init];
    gHonkScroll.translatesAutoresizingMaskIntoConstraints = NO;
    gHonkScroll.alwaysBounceVertical = YES;
    gHonkScroll.delaysContentTouches = NO;
    gHonkScroll.multipleTouchEnabled = YES;
    UIStackView *content = [[UIStackView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 10;
    content.layoutMargins = UIEdgeInsetsMake(3, 2, 8, 2);
    content.layoutMarginsRelativeArrangement = YES;
    [gHonkScroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:gHonkScroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:gHonkScroll.contentLayoutGuide.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:gHonkScroll.contentLayoutGuide.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:gHonkScroll.contentLayoutGuide.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:gHonkScroll.frameLayoutGuide.widthAnchor],
    ]];
    [outer addArrangedSubview:gHonkScroll];
    gHonkContent = content;
    [self renderCurrentPage];

    if (!gHonkRefresh)
        gHonkRefresh = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}

+ (void)renderCurrentPage { HonkBuildPage(gSelectedPage); }

+ (void)refresh {
    HonkResolveGuest();
    UIWindow *window = HonkGameWindow();
    if (window && window.rootViewController.view != gHonkRoot.superview) [self installWhenReady];
}

+ (void)selectPage:(id)sender {
    NSInteger page = ((UIButton *)sender).tag - 10;
    if (page < 0 || page > 5) return;
    gSelectedPage = page;
    [self renderCurrentPage];
}

+ (void)settingChanged:(id)sender {
    HonkResolveGuest();
    if (!gHonkState) return;
    if ([sender isKindOfClass:UISwitch.class]) {
        const BOOL enabled = ((UISwitch *)sender).on;
        HonkFeatures::setJumpEnabled(gHonkState, enabled);
        [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"HonkMenu.JumpEnabled"];
    } else if ([sender isKindOfClass:UISlider.class]) {
        UISlider *slider = (UISlider *)sender;
        if (slider.tag == 2) {
            HonkFeatures::setJumpImpulse(gHonkState, slider.value);
            gHonkImpulseValue.text = [NSString stringWithFormat:@"%.1f units/s", slider.value];
            [NSUserDefaults.standardUserDefaults setFloat:slider.value forKey:@"HonkMenu.JumpImpulse"];
        } else if (slider.tag == 3) {
            HonkFeatures::setSpeedFactor(gHonkState, slider.value);
            gHonkSpeedValue.text = [NSString stringWithFormat:@"%.0f%%", slider.value * 100.0f];
            [NSUserDefaults.standardUserDefaults setFloat:slider.value forKey:@"HonkMenu.SpeedFactor"];
        }
    }
}

+ (void)menuAction:(id)sender {
    UIButton *button = (UIButton *)sender;
    if (button.tag == 0) {
        gHonkPanel.hidden = !gHonkPanel.hidden;
        [gHonkLauncher setTitle:gHonkPanel.hidden ? @"HM" : @"×" forState:UIControlStateNormal];
        return;
    }
    if (button.tag == -1) {
        gHonkPanel.hidden = YES;
        [gHonkLauncher setTitle:@"HM" forState:UIControlStateNormal];
        return;
    }
    HonkResolveGuest();
    if (!gHonkState) return;
    switch (button.tag) {
        case 1: (void)HonkFeatures::publishCommand(gHonkState, HonkFeatures::kCommandSavePosition); break;
        case 2: (void)HonkFeatures::publishCommand(gHonkState, HonkFeatures::kCommandRestorePosition); break;
        default: {
            NSInteger preset = button.tag - 100;
            if (preset >= 0 && preset < (NSInteger)(sizeof(kPresets) / sizeof(kPresets[0]))) {
                const HonkTeleportPreset &p = kPresets[preset];
                (void)HonkFeatures::publishTeleport(gHonkState, p.x, p.y, p.z);
            }
            break;
        }
    }
}

+ (void)lifecycleEnded:(NSNotification *)notification {
    (void)notification;
    if (gHonkState) {
        GooseJumpInput::clear(&gHonkState->pendingState);
        __atomic_store_n(&gHonkState->command, HonkFeatures::kCommandNone, __ATOMIC_RELEASE);
    }
}

@end
