#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <MediaPlayer/MediaPlayer.h>

#import "NBZActionBar.h"
#import "NBZArtistLists.h"
#import "NBZGuard.h"
#import "NBZPlayerUI.h"
#import "NBZProviders.h"
#import "NBZScrobble.h"
#import "NBZSettingsVC.h"
#import "NBZUtil.h"

static IMP nbz_orig_avatarLayout;

static void NBZSwizzle(Class cls, SEL sel, IMP newIMP, IMP *original) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        NBZLog(@"swizzle: -[%@ %@] not found", NSStringFromClass(cls), NSStringFromSelector(sel));
        return;
    }
    *original = method_getImplementation(method);
    // class_getInstanceMethod returns inherited methods too; calling
    // method_setImplementation on those would patch the superclass and hit
    // every view controller in the app. Add an own copy first in that case.
    if (class_addMethod(cls, sel, newIMP, method_getTypeEncoding(method))) {
        NBZLog(@"swizzle: hooked -[%@ %@] (added)", NSStringFromClass(cls), NSStringFromSelector(sel));
        return;
    }
    method_setImplementation(method, newIMP);
    NBZLog(@"swizzle: hooked -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel));
}


static void NBZPresentSettings(UIViewController *presenter) {
    NBZSettingsViewController *settings = [NBZSettingsViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [presenter presentViewController:nav animated:YES completion:nil];
}


// The account page's own list: a UIScrollView whose *direct* children are the
// YTMAccountButton rows. YTMAvatarAccountView is itself a scroll view, so the
// check has to look one level down rather than at the view it is called on.
static UIScrollView *NBZFindAccountScrollView(UIView *view) {
    if ([view isKindOfClass:[UIScrollView class]]) {
        for (UIView *sub in view.subviews) {
            if ([NSStringFromClass(sub.class) isEqualToString:@"YTMAccountButton"]) return (UIScrollView *)view;
        }
    }
    for (UIView *sub in view.subviews) {
        UIScrollView *hit = NBZFindAccountScrollView(sub);
        if (hit) return hit;
    }
    return nil;
}

static const NSInteger kNBZAccountRowTag = 0x4E42425B;
static char kNBZAccountRowKey;

static UIViewController *NBZViewControllerForView(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) return (UIViewController *)responder;
        responder = responder.nextResponder;
    }
    return nil;
}

static UILabel *NBZFirstLabel(UIView *view) {
    if ([view isKindOfClass:[UILabel class]] && [(UILabel *)view text].length) return (UILabel *)view;
    for (UIView *sub in view.subviews) {
        UILabel *label = NBZFirstLabel(sub);
        if (label) return label;
    }
    return nil;
}

static UIImageView *NBZFirstImageView(UIView *view) {
    if ([view isKindOfClass:[UIImageView class]] && CGRectGetWidth(view.bounds) > 0) return (UIImageView *)view;
    for (UIView *sub in view.subviews) {
        UIImageView *imageView = NBZFirstImageView(sub);
        if (imageView) return imageView;
    }
    return nil;
}

// The icon is baked with the colour the native rows' titles actually render in
// (resolved against the page's own traits), at the native icon box size. The
// earlier version used labelColor resolved in a light-trait renderer, which is
// black on this dark page, hence "invisible".
static UIImage *NBZAccountRowIcon(NSString *name, UIView *nativeRow) {
    UILabel *label = NBZFirstLabel(nativeRow);
    UIColor *color = label.textColor ?: [UIColor whiteColor];
    color = [color resolvedColorWithTraitCollection:nativeRow.traitCollection];
    UIImageView *nativeIcon = NBZFirstImageView(nativeRow);
    CGFloat side = nativeIcon ? MIN(CGRectGetWidth(nativeIcon.bounds), CGRectGetHeight(nativeIcon.bounds)) : 24;
    if (side < 12) side = 24;

    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:side * 0.75 weight:UIImageSymbolWeightRegular];
    UIImage *symbol = [UIImage systemImageNamed:name withConfiguration:config];
    symbol = [symbol imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGSize s = symbol.size;
        CGFloat scale = MIN(side * 0.85 / s.width, side * 0.85 / s.height);
        CGSize fitted = CGSizeMake(s.width * scale, s.height * scale);
        [symbol drawInRect:CGRectMake((side - fitted.width) / 2.0, (side - fitted.height) / 2.0,
                                      fitted.width, fitted.height)];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}


// Add a real YTMAccountButton to the account page's own button list and lay it
// out with the same metrics the app uses. Doing this from layoutSubviews means
// the row is part of the first render, not bolted on afterwards, and the type,
// icon box and row pitch are the app's rather than ours.
static void NBZLayoutAccountRow(UIView *avatarView) {
    UIScrollView *scroll = NBZFindAccountScrollView(avatarView);
    if (!scroll) return;
    Class buttonClass = NSClassFromString(@"YTMAccountButton");
    if (!buttonClass) return;

    NSMutableArray<UIView *> *native = [NSMutableArray array];
    for (UIView *sub in scroll.subviews) {
        if ([sub isKindOfClass:buttonClass] && sub.tag != kNBZAccountRowTag) [native addObject:sub];
    }
    if (!native.count) return;

    UIView *row = objc_getAssociatedObject(scroll, &kNBZAccountRowKey);
    if (!row) {
        SEL initSel = NSSelectorFromString(@"initWithTitle:identifier:icon:actionBlock:");
        if (![buttonClass instancesRespondToSelector:initSel]) {
            NBZLog(@"account row: YTMAccountButton lacks initWithTitle:identifier:icon:actionBlock:");
            return;
        }
        __weak UIView *weakAvatar = avatarView;
        id button = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)([buttonClass alloc], initSel,
            @"Nibblez", @"nibblez", NBZAccountRowIcon(@"waveform", native.firstObject),
            ^(BOOL finished) {
                UIViewController *presenter = weakAvatar ? NBZViewControllerForView(weakAvatar) : nil;
                presenter = presenter ?: UIApplication.sharedApplication.keyWindow.rootViewController;
                if (presenter) NBZPresentSettings(presenter);
            });
        if (!button) return;
        row = button;
        row.tag = kNBZAccountRowTag;
        [scroll addSubview:row];
        objc_setAssociatedObject(scroll, &kNBZAccountRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NBZLog(@"account row: YTMAccountButton added (%lu native rows)", (unsigned long)native.count);
    }

    // Sit directly above the last native row (Withdraw from contract) and push
    // that row down by one pitch, so the entry is visible without scrolling and
    // the row pitch / height / font stay the app's.
    UIView *last = native.firstObject;
    for (UIView *candidate in native) {
        if (CGRectGetMaxY(candidate.frame) > CGRectGetMaxY(last.frame)) last = candidate;
    }
    CGFloat pitch = CGRectGetHeight(last.frame);
    if (pitch < 1) pitch = 48;

    CGRect rowFrame = last.frame;
    CGRect shifted = last.frame;
    shifted.origin.y = CGRectGetMinY(last.frame) + pitch;
    if (!CGRectEqualToRect(last.frame, shifted)) last.frame = shifted;
    if (!CGRectEqualToRect(row.frame, rowFrame)) row.frame = rowFrame;

    CGFloat needed = CGRectGetMaxY(shifted) + 8;
    if (scroll.contentSize.height < needed) {
        scroll.contentSize = CGSizeMake(scroll.contentSize.width, needed);
    }
}

static void NBZInstallHooks(void) {
    // Block pill: a real item of the now-playing action row (see NBZActionBar.m).
    NBZInstallActionBarHooks();

    Class avatarView = NSClassFromString(@"YTMAvatarAccountView");
    if (avatarView) {
        NBZSwizzle(avatarView, @selector(layoutSubviews),
            imp_implementationWithBlock(^(UIView *self) {
                ((void (*)(id, SEL))nbz_orig_avatarLayout)(self, @selector(layoutSubviews));
                NBZLayoutAccountRow(self);
            }), &nbz_orig_avatarLayout);
    } else {
        NBZLog(@"YTMAvatarAccountView missing");
    }

    // Entry point: the row is injected into the account page itself
    // (YTMAvatarAccountViewController), see NBZInstallAccountRow. The iPhone
    // setAccountMenuUpperButtons:lowerButtons: API is not used: on iPad it is
    // never called and the swizzle only added a crash path.
}

__attribute__((constructor)) static void NBZNibblezInit(void) {
    @autoreleasepool {
        NBZLog(@"Nibblez %@ loading", @NIBBLEZ_VERSION);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NBZInstallHooks();
            [[NBZScrobbler shared] start];
            [[NBZArtistLists shared] start];
            [[NBZGuard shared] start];
            [[NBZPlayerUI shared] installRemoteCommands];
            [[NBZPlayerUI shared] installAppHooks];
        });
    }
}
