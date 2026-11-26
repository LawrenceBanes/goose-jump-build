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
static UILabel *gHonkTimeScaleValue;
static UILabel *gHonkSizeValue;
static UILabel *gHonkCameraValue;
static UILabel *gHonkCameraPositionLabel;
static UILabel *gHonkCameraStepValue;
static UISwitch *gHonkFreeCameraSwitch;
static UISwitch *gHonkFirstPersonSwitch;
static float gHonkFreeCameraStep = 0.5f;
static UILabel *gHonkNpcSizeValue;
static UIView *gHonkNpcOverlay;
static NSTimer *gHonkRefresh;
static NSInteger gSelectedPage = 0;

@interface HonkPassthroughView : UIView
@end

@interface HonkNpcOverlayView : UIView
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

@implementation HonkNpcOverlayView
- (void)drawRect:(CGRect)rect {
    (void)rect;
    if (!HonkFeatures::npcTrackingEnabled(gHonkState)) return;
    const uint32_t width = __atomic_load_n(&gHonkState->npcScreenWidth, __ATOMIC_ACQUIRE);
    const uint32_t height = __atomic_load_n(&gHonkState->npcScreenHeight, __ATOMIC_ACQUIRE);
    if (!width || !height) return;
    const CGSize size = self.bounds.size;
    NSDictionary *attributes = @{
        NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: UIColor.systemRedColor,
    };
    for (uint32_t i = 0; i < HONK_NPC_SCALE_ENTRY_COUNT; ++i) {
        const HonkNpcScaleEntry &entry = gHonkState->npcScaleEntries[i];
        if (!__atomic_load_n(&entry.body, __ATOMIC_ACQUIRE) ||
            !__atomic_load_n(&entry.visible, __ATOMIC_ACQUIRE)) continue;
        const float sx = GooseJumpInput::bitsFloat(
            __atomic_load_n(reinterpret_cast<const uint32_t *>(&entry.screenX), __ATOMIC_ACQUIRE));
        const float sy = GooseJumpInput::bitsFloat(
            __atomic_load_n(reinterpret_cast<const uint32_t *>(&entry.screenY), __ATOMIC_ACQUIRE));
        if (!std::isfinite(sx) || !std::isfinite(sy)) continue;
        const CGFloat x = sx * size.width / width;
        const CGFloat y = (height - sy) * size.height / height;
        CGRect dot = CGRectMake(x - 4, y - 4, 8, 8);
        [UIColor.systemRedColor setFill];
        [[UIBezierPath bezierPathWithOvalInRect:dot] fill];
        [@"NPC" drawAtPoint:CGPointMake(x + 6, y - 8) withAttributes:attributes];
    }
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
    switch (tag) {
        case 2: valueLabel.text = [NSString stringWithFormat:@"%.1f units/s", value]; break;
        case 6: valueLabel.text = [NSString stringWithFormat:@"%.2fx", value]; break;
        case 7: valueLabel.text = [NSString stringWithFormat:@"%.0f%%", value * 100.0f]; break;
        case 8: valueLabel.text = [NSString stringWithFormat:@"%.0f%%", value * 100.0f]; break;
        case 15: valueLabel.text = [NSString stringWithFormat:@"%.1f units", value]; break;
        default: valueLabel.text = [NSString stringWithFormat:@"%.0f%%", value * 100.0f]; break;
    }
    [row addArrangedSubview:valueLabel];
    HonkAddRow(stack, row);
    if (tag == 2) gHonkImpulseValue = valueLabel;
    if (tag == 3) gHonkSpeedValue = valueLabel;
    if (tag == 6) gHonkTimeScaleValue = valueLabel;
    if (tag == 7) gHonkSizeValue = valueLabel;
    if (tag == 8) gHonkCameraValue = valueLabel;
    if (tag == 11) gHonkNpcSizeValue = valueLabel;
    if (tag == 15) gHonkCameraStepValue = valueLabel;
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

    UISwitch *hover = [[UISwitch alloc] init];
    hover.tag = 4;
    hover.on = HonkFeatures::hoverEnabled(gHonkState);
    [hover addTarget:[NSClassFromString(@"HonkMenuOverlay") class]
              action:@selector(settingChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *hoverRow = [[UIStackView alloc] init];
    hoverRow.axis = UILayoutConstraintAxisHorizontal;
    hoverRow.alignment = UIStackViewAlignmentCenter;
    hoverRow.distribution = UIStackViewDistributionEqualSpacing;
    [hoverRow addArrangedSubview:HonkLabel(@"Float / hold height", UIFontWeightSemibold, 15, UIColor.whiteColor)];
    [hoverRow addArrangedSubview:hover];
    HonkAddRow(gHonkContent, hoverRow);
    HonkAddRow(gHonkContent, HonkLabel(@"Holds vertical Rigidbody velocity at zero. Collision stays enabled; this is not noclip. Automatically yields while swimming or dragging.", UIFontWeightRegular, 12, UIColor.lightTextColor));

    UISwitch *timeEnabled = [[UISwitch alloc] init];
    timeEnabled.tag = 5;
    timeEnabled.on = HonkFeatures::timeScaleEnabled(gHonkState);
    [timeEnabled addTarget:[NSClassFromString(@"HonkMenuOverlay") class]
                    action:@selector(settingChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *timeRow = [[UIStackView alloc] init];
    timeRow.axis = UILayoutConstraintAxisHorizontal;
    timeRow.alignment = UIStackViewAlignmentCenter;
    timeRow.distribution = UIStackViewDistributionEqualSpacing;
    [timeRow addArrangedSubview:HonkLabel(@"Custom game speed", UIFontWeightSemibold, 15, UIColor.whiteColor)];
    [timeRow addArrangedSubview:timeEnabled];
    HonkAddRow(gHonkContent, timeRow);
    HonkSlider(gHonkContent, @"Game speed", HonkFeatures::kMinimumTimeScale,
               HonkFeatures::kMaximumTimeScale, HonkFeatures::timeScale(gHonkState), 6);
    HonkSlider(gHonkContent, @"Goose size", HonkFeatures::kMinimumSizeFactor,
               HonkFeatures::kMaximumSizeFactor, HonkFeatures::sizeFactor(gHonkState), 7);
    HonkAddRow(gHonkContent, HonkLabel(@"Camera", UIFontWeightBold, 17, UIColor.systemTealColor));
    HonkSlider(gHonkContent, @"Follow camera distance", HonkFeatures::kMinimumCameraFactor,
               HonkFeatures::kMaximumCameraFactor, HonkFeatures::cameraFactor(gHonkState), 8);
    HonkAddUnavailable(@"Noclip", @"Scene collider pairs are not yet enumerated safely; world collision remains enabled");
    HonkAddUnavailable(@"Noclip", @"this build exposes no verified reversible Collider setter; world collision remains enabled");
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
            gHonkCameraPositionLabel = HonkLabel(@"Camera position: waiting for gameplay", UIFontWeightRegular, 12, UIColor.lightTextColor);
            HonkAddRow(gHonkContent, gHonkCameraPositionLabel);
            gHonkFreeCameraSwitch = [[UISwitch alloc] init];
            gHonkFreeCameraSwitch.tag = 14;
            gHonkFreeCameraSwitch.on = HonkFeatures::freeCameraEnabled(gHonkState);
            gHonkFreeCameraSwitch.multipleTouchEnabled = YES;
            gHonkFreeCameraSwitch.exclusiveTouch = NO;
            [gHonkFreeCameraSwitch addTarget:[NSClassFromString(@"HonkMenuOverlay") class]
                                      action:@selector(settingChanged:) forControlEvents:UIControlEventValueChanged];
            UIStackView *freeCameraRow = [[UIStackView alloc] init];
            freeCameraRow.axis = UILayoutConstraintAxisHorizontal;
            freeCameraRow.alignment = UIStackViewAlignmentCenter;
            freeCameraRow.distribution = UIStackViewDistributionEqualSpacing;
            [freeCameraRow addArrangedSubview:HonkLabel(@"Free camera", UIFontWeightSemibold, 15, UIColor.whiteColor)];
            [freeCameraRow addArrangedSubview:gHonkFreeCameraSwitch];
            HonkAddRow(gHonkContent, freeCameraRow);
            HonkAddRow(gHonkContent, HonkLabel(@"Freezes the follow rig and moves the existing game camera in 0.5-unit world-axis steps. Camera rotation stays fixed.", UIFontWeightRegular, 12, UIColor.lightTextColor));
            gHonkFirstPersonSwitch = [[UISwitch alloc] init];
            gHonkFirstPersonSwitch.tag = 16;
            gHonkFirstPersonSwitch.on = HonkFeatures::firstPersonCameraEnabled(gHonkState);
            gHonkFirstPersonSwitch.multipleTouchEnabled = YES;
            gHonkFirstPersonSwitch.exclusiveTouch = NO;
            [gHonkFirstPersonSwitch addTarget:[NSClassFromString(@"HonkMenuOverlay") class]
                                       action:@selector(settingChanged:) forControlEvents:UIControlEventValueChanged];
            UIStackView *firstPersonRow = [[UIStackView alloc] init];
            firstPersonRow.axis = UILayoutConstraintAxisHorizontal;
            firstPersonRow.alignment = UIStackViewAlignmentCenter;
            firstPersonRow.distribution = UIStackViewDistributionEqualSpacing;
            [firstPersonRow addArrangedSubview:HonkLabel(@"First-person camera", UIFontWeightSemibold, 15, UIColor.whiteColor)];
            [firstPersonRow addArrangedSubview:gHonkFirstPersonSwitch];
            HonkAddRow(gHonkContent, firstPersonRow);
            HonkAddRow(gHonkContent, HonkLabel(@"Moves the existing game camera to the goose head and follows its rotation. Enable only during gameplay.", UIFontWeightRegular, 12, UIColor.lightTextColor));
            {
                NSNumber *storedStep = [NSUserDefaults.standardUserDefaults objectForKey:@"HonkMenu.FreeCameraStep"];
                gHonkFreeCameraStep = storedStep ? fminf(fmaxf(storedStep.floatValue, 0.1f), 2.0f) : 0.5f;
                HonkSlider(gHonkContent, @"Free camera move step", 0.1f, 2.0f, gHonkFreeCameraStep, 15);
            }
            {
                UIStackView *vertical = [[UIStackView alloc] init];
                vertical.axis = UILayoutConstraintAxisHorizontal;
                vertical.distribution = UIStackViewDistributionFillEqually;
                [vertical addArrangedSubview:HonkButton(@"Up", 220, [NSClassFromString(@"HonkMenuOverlay") class], @selector(menuAction:))];
                [vertical addArrangedSubview:HonkButton(@"Down", 221, [NSClassFromString(@"HonkMenuOverlay") class], @selector(menuAction:))];
                HonkAddRow(gHonkContent, vertical);
                UIStackView *lateral = [[UIStackView alloc] init];
                lateral.axis = UILayoutConstraintAxisHorizontal;
                lateral.distribution = UIStackViewDistributionFillEqually;
                [lateral addArrangedSubview:HonkButton(@"Left", 222, [NSClassFromString(@"HonkMenuOverlay") class], @selector(menuAction:))];
                [lateral addArrangedSubview:HonkButton(@"Right", 223, [NSClassFromString(@"HonkMenuOverlay") class], @selector(menuAction:))];
                HonkAddRow(gHonkContent, lateral);
                UIStackView *depth = [[UIStackView alloc] init];
                depth.axis = UILayoutConstraintAxisHorizontal;
                depth.distribution = UIStackViewDistributionFillEqually;
                [depth addArrangedSubview:HonkButton(@"Forward", 224, [NSClassFromString(@"HonkMenuOverlay") class], @selector(menuAction:))];
                [depth addArrangedSubview:HonkButton(@"Back", 225, [NSClassFromString(@"HonkMenuOverlay") class], @selector(menuAction:))];
                HonkAddRow(gHonkContent, depth);
            }
            HonkAddRow(gHonkContent, HonkButton(@"Teleport goose to current camera", 3,
                                                [NSClassFromString(@"HonkMenuOverlay") class],
                                                @selector(menuAction:)));
            HonkAddRow(gHonkContent, HonkLabel(@"Uses the live follow-camera position. Save your location first if testing near obstacles.", UIFontWeightRegular, 12, UIColor.lightTextColor));
            HonkAddRow(gHonkContent, HonkLabel(@"Follow camera distance is available under Move → Camera.", UIFontWeightRegular, 12, UIColor.lightTextColor));
            break;
        case 3:
            {
            UISwitch *disableShoo = [[UISwitch alloc] init];
            disableShoo.tag = 9;
            disableShoo.on = HonkFeatures::disableNpcShoo(gHonkState);
            disableShoo.multipleTouchEnabled = YES;
            disableShoo.exclusiveTouch = NO;
            [disableShoo addTarget:[NSClassFromString(@"HonkMenuOverlay") class]
                            action:@selector(settingChanged:) forControlEvents:UIControlEventValueChanged];
            UIStackView *shooRow = [[UIStackView alloc] init];
            shooRow.axis = UILayoutConstraintAxisHorizontal;
            shooRow.alignment = UIStackViewAlignmentCenter;
            shooRow.distribution = UIStackViewDistributionEqualSpacing;
            [shooRow addArrangedSubview:HonkLabel(@"Disable NPC shoo", UIFontWeightSemibold, 15, UIColor.whiteColor)];
            [shooRow addArrangedSubview:disableShoo];
            HonkAddRow(gHonkContent, shooRow);
            HonkAddRow(gHonkContent, HonkLabel(@"Prevents the goose-shoo cooldown from advancing while enabled. Existing NPC behavior resumes when disabled.", UIFontWeightRegular, 12, UIColor.lightTextColor));
            }
            HonkSlider(gHonkContent, @"NPC size (active people)", HonkFeatures::kMinimumNpcSizeFactor,
                       HonkFeatures::kMaximumNpcSizeFactor, HonkFeatures::npcSizeFactor(gHonkState), 11);
            HonkAddRow(gHonkContent, HonkLabel(@"Scales each live Body from its captured original transform. Reset to 100% to restore. The table covers up to 32 active people and resets when the goose scene instance changes.", UIFontWeightRegular, 12, UIColor.lightTextColor));
            {
                UISwitch *tracking = [[UISwitch alloc] init];
                tracking.tag = 12;
                tracking.on = HonkFeatures::npcTrackingEnabled(gHonkState);
                tracking.multipleTouchEnabled = YES;
                tracking.exclusiveTouch = NO;
                [tracking addTarget:[NSClassFromString(@"HonkMenuOverlay") class]
                             action:@selector(settingChanged:) forControlEvents:UIControlEventValueChanged];
                UIStackView *trackingRow = [[UIStackView alloc] init];
                trackingRow.axis = UILayoutConstraintAxisHorizontal;
                trackingRow.alignment = UIStackViewAlignmentCenter;
                trackingRow.distribution = UIStackViewDistributionEqualSpacing;
                [trackingRow addArrangedSubview:HonkLabel(@"NPC tracking markers", UIFontWeightSemibold, 15, UIColor.whiteColor)];
                [trackingRow addArrangedSubview:tracking];
                HonkAddRow(gHonkContent, trackingRow);
                HonkAddRow(gHonkContent, HonkLabel(@"Projects active Body components through Camera.main.WorldToScreenPoint. Labels are generic because managed object names are not resolved.", UIFontWeightRegular, 12, UIColor.lightTextColor));
            }
            break;
        case 4:
            HonkAddUnavailable(@"Item teleport / spawning", @"scene object identity and ownership are not mapped");
            HonkAddUnavailable(@"Task completion", @"progression state has not been mapped; unsafe to modify");
            HonkAddUnavailable(@"Collider visualization", @"render-thread drawing integration is not implemented");
            break;
        case 5:
            HonkAddRow(gHonkContent, HonkLabel(@"Create at the goose (replaces the previous test primitive)", UIFontWeightRegular, 12, UIColor.lightTextColor));
            {
                const char *titles[] = {"Sphere", "Capsule", "Cylinder", "Cube"};
                const uint32_t commands[] = {
                    HonkFeatures::kCommandCreateSphere,
                    HonkFeatures::kCommandCreateCapsule,
                    HonkFeatures::kCommandCreateCylinder,
                    HonkFeatures::kCommandCreateCube,
                };
                for (NSInteger i = 0; i < 4; ++i) {
                    HonkAddRow(gHonkContent, HonkButton([NSString stringWithUTF8String:titles[i]],
                                                        200 + (NSInteger)commands[i],
                                                        [NSClassFromString(@"HonkMenuOverlay") class],
                                                        @selector(menuAction:)));
                }
                HonkAddRow(gHonkContent, HonkButton(@"Remove test primitive", 210,
                                                    [NSClassFromString(@"HonkMenuOverlay") class],
                                                    @selector(menuAction:)));
            }
            HonkAddRow(gHonkContent, HonkLabel(@"Creates a Unity primitive with its normal renderer and collider, 1.5 units above the goose. Creating another replaces it. These test objects are not game items.", UIFontWeightRegular, 12, UIColor.lightTextColor));
            HonkAddUnavailable(@"Cloning NPCs / Goose", @"A stable user-selectable source object and lifetime-safe clone registry are not implemented");
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
    NSNumber *hoverPreference = [defaults objectForKey:@"HonkMenu.FloatEnabled"];
    NSNumber *timeEnabledPreference = [defaults objectForKey:@"HonkMenu.TimeScaleEnabled"];
    NSNumber *timeScalePreference = [defaults objectForKey:@"HonkMenu.TimeScale"];
    NSNumber *sizePreference = [defaults objectForKey:@"HonkMenu.SizeFactor"];
    NSNumber *cameraPreference = [defaults objectForKey:@"HonkMenu.CameraFactor"];
    NSNumber *npcSizePreference = [defaults objectForKey:@"HonkMenu.NpcSizeFactor"];
    NSNumber *npcTrackingPreference = [defaults objectForKey:@"HonkMenu.NpcTracking"];
    NSNumber *shooPreference = [defaults objectForKey:@"HonkMenu.DisableNpcShoo"];
    HonkFeatures::setJumpEnabled(gHonkState, jumpPreference ? jumpPreference.boolValue : true);
    HonkFeatures::setJumpImpulse(gHonkState, impulsePreference ? impulsePreference.floatValue : HonkReadJumpImpulse());
    HonkFeatures::setSpeedFactor(gHonkState, speedPreference ? speedPreference.floatValue : 1.0f);
    HonkFeatures::setHoverEnabled(gHonkState, hoverPreference ? hoverPreference.boolValue : false);
    HonkFeatures::setTimeScale(gHonkState, timeScalePreference ? timeScalePreference.floatValue : 1.0f);
    HonkFeatures::setTimeScaleEnabled(gHonkState, timeEnabledPreference ? timeEnabledPreference.boolValue : false);
    HonkFeatures::setSizeFactor(gHonkState, sizePreference ? sizePreference.floatValue : 1.0f);
    HonkFeatures::setCameraFactor(gHonkState, cameraPreference ? cameraPreference.floatValue : 1.0f);
    HonkFeatures::setNpcSizeFactor(gHonkState, npcSizePreference ? npcSizePreference.floatValue : 1.0f);
    HonkFeatures::setNpcTrackingEnabled(gHonkState, npcTrackingPreference ? npcTrackingPreference.boolValue : false);
    HonkFeatures::setDisableNpcShoo(gHonkState, shooPreference ? shooPreference.boolValue : false);

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

    HonkNpcOverlayView *npcOverlay = [[HonkNpcOverlayView alloc] initWithFrame:CGRectZero];
    npcOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    npcOverlay.backgroundColor = UIColor.clearColor;
    npcOverlay.userInteractionEnabled = NO;
    npcOverlay.multipleTouchEnabled = YES;
    gHonkNpcOverlay = npcOverlay;
    [gHonkRoot addSubview:npcOverlay];
    [NSLayoutConstraint activateConstraints:@[
        [npcOverlay.leadingAnchor constraintEqualToAnchor:gHonkRoot.leadingAnchor],
        [npcOverlay.trailingAnchor constraintEqualToAnchor:gHonkRoot.trailingAnchor],
        [npcOverlay.topAnchor constraintEqualToAnchor:gHonkRoot.topAnchor],
        [npcOverlay.bottomAnchor constraintEqualToAnchor:gHonkRoot.bottomAnchor],
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
    if (gHonkCameraPositionLabel && gHonkState &&
        __atomic_load_n(&gHonkState->cameraPositionValid, __ATOMIC_ACQUIRE)) {
        const float x = GooseJumpInput::bitsFloat(__atomic_load_n(&gHonkState->cameraPositionXBits, __ATOMIC_ACQUIRE));
        const float y = GooseJumpInput::bitsFloat(__atomic_load_n(&gHonkState->cameraPositionYBits, __ATOMIC_ACQUIRE));
        const float z = GooseJumpInput::bitsFloat(__atomic_load_n(&gHonkState->cameraPositionZBits, __ATOMIC_ACQUIRE));
        if (std::isfinite(x) && std::isfinite(y) && std::isfinite(z))
            gHonkCameraPositionLabel.text = [NSString stringWithFormat:@"Camera position: %.2f, %.2f, %.2f", x, y, z];
    } else if (gHonkCameraPositionLabel) {
        gHonkCameraPositionLabel.text = @"Camera position: waiting for gameplay";
    }
    if (gHonkFreeCameraSwitch && gHonkState)
        [gHonkFreeCameraSwitch setOn:HonkFeatures::freeCameraEnabled(gHonkState) animated:NO];
    if (gHonkFirstPersonSwitch && gHonkState)
        [gHonkFirstPersonSwitch setOn:HonkFeatures::firstPersonCameraEnabled(gHonkState) animated:NO];
    [gHonkNpcOverlay setNeedsDisplay];
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
        switch (((UISwitch *)sender).tag) {
            case 1:
                HonkFeatures::setJumpEnabled(gHonkState, enabled);
                [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"HonkMenu.JumpEnabled"];
                break;
            case 4:
                HonkFeatures::setHoverEnabled(gHonkState, enabled);
                [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"HonkMenu.FloatEnabled"];
                break;
            case 5:
                HonkFeatures::setTimeScaleEnabled(gHonkState, enabled);
                [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"HonkMenu.TimeScaleEnabled"];
                break;
            case 9:
                HonkFeatures::setDisableNpcShoo(gHonkState, enabled);
                [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"HonkMenu.DisableNpcShoo"];
                break;
            case 12:
                HonkFeatures::setNpcTrackingEnabled(gHonkState, enabled);
                [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"HonkMenu.NpcTracking"];
                [gHonkNpcOverlay setNeedsDisplay];
                break;
            case 14:
                if (!HonkFeatures::setFreeCameraEnabled(gHonkState, enabled)) {
                    ((UISwitch *)sender).on = NO;
                }
                if (enabled) [gHonkFirstPersonSwitch setOn:NO animated:NO];
                break;
            case 16:
                HonkFeatures::setFirstPersonCameraEnabled(gHonkState, enabled);
                if (enabled) [gHonkFreeCameraSwitch setOn:NO animated:NO];
                break;
        }
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
        } else if (slider.tag == 6) {
            HonkFeatures::setTimeScale(gHonkState, slider.value);
            gHonkTimeScaleValue.text = [NSString stringWithFormat:@"%.2fx", slider.value];
            [NSUserDefaults.standardUserDefaults setFloat:slider.value forKey:@"HonkMenu.TimeScale"];
        } else if (slider.tag == 7) {
            HonkFeatures::setSizeFactor(gHonkState, slider.value);
            gHonkSizeValue.text = [NSString stringWithFormat:@"%.0f%%", slider.value * 100.0f];
            [NSUserDefaults.standardUserDefaults setFloat:slider.value forKey:@"HonkMenu.SizeFactor"];
        } else if (slider.tag == 8) {
            HonkFeatures::setCameraFactor(gHonkState, slider.value);
            gHonkCameraValue.text = [NSString stringWithFormat:@"%.0f%%", slider.value * 100.0f];
            [NSUserDefaults.standardUserDefaults setFloat:slider.value forKey:@"HonkMenu.CameraFactor"];
        } else if (slider.tag == 11) {
            HonkFeatures::setNpcSizeFactor(gHonkState, slider.value);
            gHonkNpcSizeValue.text = [NSString stringWithFormat:@"%.0f%%", slider.value * 100.0f];
            [NSUserDefaults.standardUserDefaults setFloat:slider.value forKey:@"HonkMenu.NpcSizeFactor"];
        } else if (slider.tag == 15) {
            gHonkFreeCameraStep = fminf(fmaxf(slider.value, 0.1f), 2.0f);
            gHonkCameraStepValue.text = [NSString stringWithFormat:@"%.1f units", gHonkFreeCameraStep];
            [NSUserDefaults.standardUserDefaults setFloat:gHonkFreeCameraStep forKey:@"HonkMenu.FreeCameraStep"];
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
    if (button.tag >= 204 && button.tag <= 207) {
        (void)HonkFeatures::publishCommand(gHonkState, (uint32_t)(button.tag - 200));
        return;
    }
    if (button.tag == 210) {
        (void)HonkFeatures::publishCommand(gHonkState, HonkFeatures::kCommandDestroySpawned);
        return;
    }
    if (button.tag >= 220 && button.tag <= 225) {
        if (!gHonkState) return;
        switch (button.tag) {
            case 220: (void)HonkFeatures::nudgeFreeCamera(gHonkState, 0.0f, gHonkFreeCameraStep, 0.0f); break;
            case 221: (void)HonkFeatures::nudgeFreeCamera(gHonkState, 0.0f, -gHonkFreeCameraStep, 0.0f); break;
            case 222: (void)HonkFeatures::nudgeFreeCamera(gHonkState, -gHonkFreeCameraStep, 0.0f, 0.0f); break;
            case 223: (void)HonkFeatures::nudgeFreeCamera(gHonkState, gHonkFreeCameraStep, 0.0f, 0.0f); break;
            case 224: (void)HonkFeatures::nudgeFreeCamera(gHonkState, 0.0f, 0.0f, gHonkFreeCameraStep); break;
            case 225: (void)HonkFeatures::nudgeFreeCamera(gHonkState, 0.0f, 0.0f, -gHonkFreeCameraStep); break;
        }
        return;
    }
    HonkResolveGuest();
    if (!gHonkState) return;
    switch (button.tag) {
        case 1: (void)HonkFeatures::publishCommand(gHonkState, HonkFeatures::kCommandSavePosition); break;
        case 2: (void)HonkFeatures::publishCommand(gHonkState, HonkFeatures::kCommandRestorePosition); break;
        case 3: (void)HonkFeatures::publishCommand(gHonkState, HonkFeatures::kCommandTeleportToCamera); break;
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
        (void)HonkFeatures::setFreeCameraEnabled(gHonkState, false);
        HonkFeatures::setFirstPersonCameraEnabled(gHonkState, false);
    }
}

@end
