#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdint.h>
#include <string.h>

// These preferred virtual addresses are pinned to the audited source binary.
static const uintptr_t kMainImageBase = 0x100000000ULL;
static const uintptr_t kJumpDataVA = 0x102e1b000ULL;
static const uintptr_t kTimeScaleRVA = 0x1de9fe0ULL;
static const uintptr_t kUnscaledTimeRVA = 0x1de9e60ULL;
static const uint8_t kExpectedGameUUID[16] = {
    0x8c, 0x9e, 0x46, 0x8f, 0x0d, 0x54, 0x39, 0xe5,
    0x86, 0x4f, 0x17, 0x64, 0x91, 0x60, 0x76, 0x98,
};
#ifndef GOOSE_JUMP_IMPULSE
#define GOOSE_JUMP_IMPULSE 8.5f
#endif
#ifndef GOOSE_JUMP_COOLDOWN
#define GOOSE_JUMP_COOLDOWN 0.35f
#endif

typedef struct GooseJumpData {
    volatile uint32_t request;
    volatile uint32_t airborneLatch;
    float cooldownRemaining;
    float jumpImpulse;
    float cooldownSeconds;
    volatile float requestTimestamp;
    uintptr_t lastMover;
    uint32_t groundedStableFrames;
} GooseJumpData;

typedef float (*UnityFloatGetter)(const void *methodInfo);

static GooseJumpData *gJumpData;
static UnityFloatGetter gGetTimeScale;
static UnityFloatGetter gGetUnscaledTime;
static BOOL gGuestImageResolved;
// The root is replaced when UIKit rebuilds its window hierarchy; this strong
// reference is updated on each successful install and avoids file-scope weak ARC.
static UIView *gAttachedRoot;
static UIButton *gJumpButton;
static NSTimer *gRefreshTimer;

@interface GooseJumpOverlay : NSObject
+ (void)installWhenReady;
+ (void)refreshButton;
+ (void)jumpPressed:(UIButton *)sender;
+ (void)appWillResignActive:(NSNotification *)notification;
@end

static void GooseJumpScheduleRetry(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [GooseJumpOverlay installWhenReady]; });
}

static BOOL GooseJumpResolveGuestImage(void) {
    if (gGuestImageResolved) return YES;
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; ++index) {
        const struct mach_header *header = _dyld_get_image_header(index);
        if (!header || header->magic != MH_MAGIC_64) continue;
        const struct mach_header_64 *header64 = (const struct mach_header_64 *)header;
        const struct load_command *command = (const struct load_command *)(header64 + 1);
        BOOL matches = NO;
        for (uint32_t ci = 0; ci < header64->ncmds; ++ci) {
            if (command->cmdsize < sizeof(struct load_command)) break;
            if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command)) {
                const struct uuid_command *uuid = (const struct uuid_command *)command;
                matches = memcmp(uuid->uuid, kExpectedGameUUID, sizeof(kExpectedGameUUID)) == 0;
                break;
            }
            command = (const struct load_command *)((const uint8_t *)command + command->cmdsize);
        }
        if (!matches) continue;
        uintptr_t slide = (uintptr_t)_dyld_get_image_vmaddr_slide(index);
        gJumpData = (GooseJumpData *)(slide + kJumpDataVA);
        gJumpData->jumpImpulse = GOOSE_JUMP_IMPULSE;
        gJumpData->cooldownSeconds = GOOSE_JUMP_COOLDOWN;
        gGetTimeScale = (UnityFloatGetter)(slide + kMainImageBase + kTimeScaleRVA);
        gGetUnscaledTime = (UnityFloatGetter)(slide + kMainImageBase + kUnscaledTimeRVA);
        gGuestImageResolved = YES;
        return YES;
    }
    return NO;
}

static UIView *GooseJumpGuestRootView(void) {
    UIApplication *application = UIApplication.sharedApplication;
    id delegate = application.delegate;
    if (!delegate) return nil;
    NSString *className = NSStringFromClass([delegate class]);
    if ([className rangeOfString:@"UnityAppController"].location == NSNotFound) return nil;
    SEL windowSelector = NSSelectorFromString(@"window");
    if (![delegate respondsToSelector:windowSelector]) return nil;
    UIWindow *window = ((UIWindow *(*)(id, SEL))objc_msgSend)(delegate, windowSelector);
    return window.rootViewController.view;
}

@implementation GooseJumpOverlay

+ (void)load {
    GooseJumpResolveGuestImage();
    GooseJumpScheduleRetry();
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(appWillResignActive:)
        name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(appWillResignActive:)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
}

+ (void)installWhenReady {
    GooseJumpResolveGuestImage();
    UIView *root = GooseJumpGuestRootView();
    if (!root || !gJumpData || !gGetTimeScale || !gGetUnscaledTime) {
        GooseJumpScheduleRetry();
        return;
    }

    if (gAttachedRoot != root || !gJumpButton || gJumpButton.superview != root) {
        [gJumpButton removeFromSuperview];
        gJumpButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [gJumpButton setTitle:@"Jump" forState:UIControlStateNormal];
        gJumpButton.accessibilityLabel = @"Jump";
        gJumpButton.accessibilityIdentifier = @"GooseJumpButton";
        [gJumpButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        gJumpButton.titleLabel.font = [UIFont boldSystemFontOfSize:17.0];
        gJumpButton.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.72];
        gJumpButton.layer.cornerRadius = 14.0;
        gJumpButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.72].CGColor;
        gJumpButton.layer.borderWidth = 1.25;
        gJumpButton.clipsToBounds = YES;
        gJumpButton.translatesAutoresizingMaskIntoConstraints = NO;
        [gJumpButton addTarget:self action:@selector(jumpPressed:)
              forControlEvents:UIControlEventTouchDown];
        [root addSubview:gJumpButton];

        UILayoutGuide *safe = nil;
        if (@available(iOS 11.0, *)) safe = root.safeAreaLayoutGuide;
        if (safe) {
            [NSLayoutConstraint activateConstraints:@[
            [gJumpButton.widthAnchor constraintEqualToConstant:76.0],
            [gJumpButton.heightAnchor constraintEqualToConstant:56.0],
            [gJumpButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24.0],
            [gJumpButton.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor constant:48.0],
            ]];
        } else {
            UILayoutGuide *margins = root.layoutMarginsGuide;
            [NSLayoutConstraint activateConstraints:@[
                [gJumpButton.widthAnchor constraintEqualToConstant:76.0],
                [gJumpButton.heightAnchor constraintEqualToConstant:56.0],
                [gJumpButton.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor constant:-12.0],
                [gJumpButton.centerYAnchor constraintEqualToAnchor:margins.centerYAnchor constant:48.0],
            ]];
        }
        gAttachedRoot = root;
    }

    if (!gRefreshTimer) {
        gRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
            target:self selector:@selector(refreshButton) userInfo:nil repeats:YES];
    }
    [self refreshButton];
}

+ (void)refreshButton {
    GooseJumpResolveGuestImage();
    UIView *root = GooseJumpGuestRootView();
    if (root && (root != gAttachedRoot || !gJumpButton || gJumpButton.superview != root)) {
        [self installWhenReady];
        return;
    }
    if (!gJumpButton) return;
    gJumpButton.hidden = NO;
    gJumpButton.enabled = YES;
}

+ (void)jumpPressed:(UIButton *)sender {
    (void)sender;
    if (!gJumpData || !gGetTimeScale || !gGetUnscaledTime) return;
    if (gGetTimeScale(NULL) <= 0.0f) {
        __atomic_store_n(&gJumpData->request, 0, __ATOMIC_RELEASE);
        return;
    }
    gJumpData->requestTimestamp = gGetUnscaledTime(NULL);
    __atomic_store_n(&gJumpData->request, 1, __ATOMIC_RELEASE);
}

+ (void)appWillResignActive:(NSNotification *)notification {
    (void)notification;
    if (gJumpData) __atomic_store_n(&gJumpData->request, 0, __ATOMIC_RELEASE);
    return;
}

@end
