#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdint.h>
#include <string.h>

#include "JumpInputQueue.hpp"

// These preferred virtual addresses are pinned to the audited source binary.
static const uintptr_t kJumpDataVA = 0x102e1b000ULL;
static const uint8_t kExpectedGameUUID[16] = {
    0x8c, 0x9e, 0x46, 0x8f, 0x0d, 0x54, 0x39, 0xe5,
    0x86, 0x4f, 0x17, 0x64, 0x91, 0x60, 0x76, 0x98,
};

// 2.5 vs v0.1.0's effective 1.5 velocity yields about 2.78x the height
// under constant gravity. The game's 1.5 upward cap is raised only during
// positive velocity created by a jump and restored once that boost decays.
#ifndef GOOSE_JUMP_IMPULSE
#define GOOSE_JUMP_IMPULSE 2.5f
#endif

static GooseJumpData *gJumpData;
static BOOL gGuestImageResolved;
// The root is replaced when UIKit rebuilds its window hierarchy; this strong
// reference is updated on each successful install and avoids file-scope weak ARC.
static UIView *gAttachedRoot;
static UIWindow *gAttachedWindow;
static UIButton *gJumpButton;
static NSTimer *gRefreshTimer;

@interface GooseJumpOverlay : NSObject
+ (void)installWhenReady;
+ (void)refreshButton;
+ (void)recordJumpTouch;
+ (void)appWillResignActive:(NSNotification *)notification;
@end

@interface GooseJumpButton : UIButton
@end

static float GooseJumpMonotonicTime(void) {
    return (float)CACurrentMediaTime();
}

static void GooseJumpPublishClock(void) {
    if (!gJumpData) return;
    const uint32_t bits = GooseJumpInput::floatBits(GooseJumpMonotonicTime());
    __atomic_store_n(&gJumpData->hostTimeBits, bits, __ATOMIC_RELEASE);
}

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
        GooseJumpPublishClock();
        gGuestImageResolved = YES;
        return YES;
    }
    return NO;
}

static UIView *GooseJumpGuestRootView(UIWindow **outWindow) {
    UIApplication *application = UIApplication.sharedApplication;
    id delegate = application.delegate;
    if (!delegate) return nil;
    NSString *className = NSStringFromClass([delegate class]);
    if ([className rangeOfString:@"UnityAppController"].location == NSNotFound) return nil;
    SEL windowSelector = NSSelectorFromString(@"window");
    if (![delegate respondsToSelector:windowSelector]) return nil;
    UIWindow *window = ((UIWindow *(*)(id, SEL))objc_msgSend)(delegate, windowSelector);
    if (outWindow) *outWindow = window;
    return window.rootViewController.view;
}

static void GooseJumpEnableGameMultitouch(UIView *view) {
    if (!view) return;
    // Unity receives the joystick and the new Jump touch as independent
    // UITouches. Keep every view in this guest hierarchy nonexclusive.
    view.multipleTouchEnabled = YES;
    view.exclusiveTouch = NO;
    for (UIView *child in view.subviews) GooseJumpEnableGameMultitouch(child);
}

@implementation GooseJumpButton

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    if (self.hidden || !self.userInteractionEnabled || self.alpha < 0.01) return NO;
    UIBezierPath *hitShape = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                        cornerRadius:14.0];
    return [hitShape containsPoint:point];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // A touch-down is one event. Holding a finger, moving it, or receiving a
    // later touch-cancel never synthesizes repeat jumps.
    for (UITouch *touch in touches) {
        if ([self pointInside:[touch locationInView:self] withEvent:event]) {
            [GooseJumpOverlay recordJumpTouch];
        }
    }
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // The touch-down already represents an accepted request. Let UIButton
    // clear its pressed presentation; cancellation never synthesizes another
    // event. App interruptions clear the shared queue in the lifecycle hook.
    [super touchesCancelled:touches withEvent:event];
}

@end

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
    UIWindow *window = nil;
    UIView *root = GooseJumpGuestRootView(&window);
    if (!root || !window || !gJumpData) {
        GooseJumpScheduleRetry();
        return;
    }

    GooseJumpEnableGameMultitouch(window);
    GooseJumpPublishClock();

    if (gAttachedRoot != root || gAttachedWindow != window ||
        !gJumpButton || gJumpButton.superview != root) {
        [gJumpButton removeFromSuperview];
        gJumpButton = [[GooseJumpButton alloc] initWithFrame:CGRectZero];
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
        gJumpButton.multipleTouchEnabled = YES;
        gJumpButton.exclusiveTouch = NO;
        gJumpButton.translatesAutoresizingMaskIntoConstraints = NO;
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
        gAttachedWindow = window;
    }

    if (!gRefreshTimer) {
        gRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
            target:self selector:@selector(refreshButton) userInfo:nil repeats:YES];
    }
    [self refreshButton];
}

+ (void)refreshButton {
    GooseJumpResolveGuestImage();
    GooseJumpPublishClock();
    UIWindow *window = nil;
    UIView *root = GooseJumpGuestRootView(&window);
    if (root && (root != gAttachedRoot || window != gAttachedWindow ||
                 !gJumpButton || gJumpButton.superview != root)) {
        [self installWhenReady];
        return;
    }
    if (!gJumpButton) return;
    gJumpButton.hidden = NO;
    gJumpButton.enabled = YES;
}

+ (void)recordJumpTouch {
    if (!gJumpData) return;
    const float now = GooseJumpMonotonicTime();
    __atomic_store_n(&gJumpData->hostTimeBits, GooseJumpInput::floatBits(now), __ATOMIC_RELEASE);
    (void)GooseJumpInput::enqueue(&gJumpData->pendingState, now);
}

+ (void)appWillResignActive:(NSNotification *)notification {
    (void)notification;
    if (gJumpData) GooseJumpInput::clear(&gJumpData->pendingState);
}

@end
