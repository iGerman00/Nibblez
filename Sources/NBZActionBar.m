#import "NBZActionBar.h"
#import "NBZPlayerUI.h"
#import "NBZProviders.h"
#import "NBZUtil.h"
#import <objc/runtime.h>
#import <objc/message.h>

// Everything below talks to Texture / IGListKit classes that live inside the
// app binary, so there are no headers to link against. Calls go through typed
// objc_msgSend casts, and every selector that is not part of the class we
// created ourselves is checked with -respondsToSelector: first.

static NSString *const kNBZActionBarID = @"id.video.scrollable_action_bar";
static const NSUInteger kNBZControlEventTouchUpInside = 1 << 4;  // ASControlNodeEventTouchUpInside

static char kNBZBlockNodeKey;      // section controller -> our cell node
static char kNBZRefreshTriesKey;   // section controller -> NSNumber
static char kNBZCellSizeKey;       // cell node -> NSValue(CGSize)
static char kNBZPillKey;           // cell node -> pill node
static char kNBZPillFrameKey;      // cell node -> NSValue(CGRect)
static char kNBZPillFillKey;       // pill node -> UIColor

static IMP nbz_orig_viewModels;
static IMP nbz_orig_rowLayout;
static __weak id gNBZActionBarController;

#pragma mark - Small runtime helpers

static id NBZIvarObject(id obj, const char *name) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return nil;
    return object_getIvar(obj, ivar);
}

static BOOL NBZIvarBool(id obj, const char *name, BOOL fallback) {
    if (!obj) return fallback;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return fallback;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != 'B') return fallback;
    return *(BOOL *)((uint8_t *)(__bridge void *)obj + ivar_getOffset(ivar));
}

static id NBZGet(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static CGRect NBZNodeFrame(id node) {
    if (![node respondsToSelector:@selector(frame)]) return CGRectZero;
    return ((CGRect (*)(id, SEL))objc_msgSend)(node, @selector(frame));
}

static void NBZSetFrame(id node, CGRect frame) {
    ((void (*)(id, SEL, CGRect))objc_msgSend)(node, @selector(setFrame:), frame);
}

static void NBZSetObject(id node, SEL sel, id value) {
    if ([node respondsToSelector:sel]) ((void (*)(id, SEL, id))objc_msgSend)(node, sel, value);
}

static void NBZNodeSetBool(id node, SEL sel, BOOL value) {
    if ([node respondsToSelector:sel]) ((void (*)(id, SEL, BOOL))objc_msgSend)(node, sel, value);
}

static void NBZSetFloat(id node, SEL sel, CGFloat value) {
    if ([node respondsToSelector:sel]) ((void (*)(id, SEL, CGFloat))objc_msgSend)(node, sel, value);
}

static NSArray *NBZSubnodes(id node) {
    id subnodes = NBZGet(node, NSSelectorFromString(@"subnodes"));
    return [subnodes isKindOfClass:[NSArray class]] ? subnodes : @[];
}

#pragma mark - Pill style, read from the app's own pills

// Metrics of a native single-function pill (Save, Share, Download...). They are
// read from the live row whenever its nodes have been laid out; the fallback
// values are what that same measurement returns on YT Music 2026-11 / iPad.
typedef struct {
    CGFloat cellHeight;   // item slot height
    CGFloat pillY;        // pill top inside the slot
    CGFloat pillHeight;
    CGFloat leading;      // pill edge -> icon
    CGFloat iconSize;
    CGFloat gap;          // icon -> label
    CGFloat trailing;     // label -> pill edge
    CGFloat itemGap;      // pill edge -> next item (inside the slot)
} NBZPillMetrics;

static const NBZPillMetrics kNBZFallbackMetrics = {48, 6, 36, 13, 24, 6, 17, 8};

@interface NBZPillStyle : NSObject
@property (nonatomic) NBZPillMetrics metrics;
@property (nonatomic, strong) UIColor *fill;
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic, copy) NSDictionary<NSAttributedStringKey, id> *textAttributes;
@property (nonatomic) BOOL measured;
@end
@implementation NBZPillStyle
@end

static NBZPillStyle *NBZFallbackStyle(void) {
    NBZPillStyle *style = [NBZPillStyle new];
    style.metrics = kNBZFallbackMetrics;
    style.fill = [UIColor colorWithWhite:1 alpha:26.0 / 255.0];
    style.cornerRadius = kNBZFallbackMetrics.pillHeight / 2.0;
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.minimumLineHeight = 18;
    paragraph.maximumLineHeight = 18;
    style.textAttributes = @{
        NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:241.0 / 255.0 alpha:1],
        NSParagraphStyleAttributeName: paragraph,
    };
    return style;
}

static CGFloat NBZColorAlpha(UIColor *color) {
    if (![color isKindOfClass:[UIColor class]]) return 0;
    CGFloat alpha = 0;
    if (![color getWhite:NULL alpha:&alpha]) [color getRed:NULL green:NULL blue:NULL alpha:&alpha];
    return alpha;
}

static BOOL NBZColorIsVisible(UIColor *color) {
    return NBZColorAlpha(color) > 0.01;
}

// Depth-first search for the rounded, filled node of a pill. `origin` comes
// back as that node's origin in the cell's coordinate space.
static id NBZFindPillNode(id node, CGPoint offset, CGPoint *origin, int depth) {
    if (!node || depth > 6) return nil;
    CGRect frame = NBZNodeFrame(node);
    CGPoint here = depth == 0 ? CGPointZero : CGPointMake(offset.x + frame.origin.x, offset.y + frame.origin.y);
    if (depth > 0 && [node respondsToSelector:@selector(cornerRadius)]) {
        CGFloat radius = ((CGFloat (*)(id, SEL))objc_msgSend)(node, @selector(cornerRadius));
        if (radius > 1 && NBZColorIsVisible(NBZGet(node, @selector(backgroundColor)))) {
            if (origin) *origin = here;
            return node;
        }
    }
    for (id sub in NBZSubnodes(node)) {
        id found = NBZFindPillNode(sub, here, origin, depth + 1);
        if (found) return found;
    }
    return nil;
}

static NBZPillStyle *NBZStyleFromNativeNodes(NSArray *nodes) {
    NBZPillStyle *fallback = NBZFallbackStyle();
    // Item 0 is the compound like/dislike pill; the plain pills come after it.
    for (NSUInteger i = 1; i < nodes.count; i++) {
        id cell = nodes[i];
        CGPoint pillOrigin = CGPointZero;
        id pill = NBZFindPillNode(cell, CGPointZero, &pillOrigin, 0);
        if (!pill) continue;
        id icon = nil, text = nil;
        for (id sub in NBZSubnodes(pill)) {
            if (!icon && [NSStringFromClass([sub class]) containsString:@"Image"]) icon = sub;
            NSAttributedString *string = NBZGet(sub, @selector(attributedText));
            if (!text && [string isKindOfClass:[NSAttributedString class]] && string.length) text = sub;
        }
        if (!icon || !text) continue;

        NBZPillStyle *style = [NBZPillStyle new];
        style.fill = NBZGet(pill, @selector(backgroundColor));
        style.cornerRadius = ((CGFloat (*)(id, SEL))objc_msgSend)(pill, @selector(cornerRadius));
        NSAttributedString *string = NBZGet(text, @selector(attributedText));
        style.textAttributes = [string attributesAtIndex:0 effectiveRange:NULL] ?: fallback.textAttributes;

        CGRect cellFrame = NBZNodeFrame(cell);
        CGRect pillFrame = NBZNodeFrame(pill);
        CGRect iconFrame = NBZNodeFrame(icon);
        CGRect textFrame = NBZNodeFrame(text);
        BOOL laidOut = cellFrame.size.height > 0 && pillFrame.size.height > 0 &&
                       iconFrame.size.width > 0 && textFrame.size.width > 0;
        if (laidOut) {
            NBZPillMetrics m;
            m.cellHeight = cellFrame.size.height;
            m.pillY = pillOrigin.y;
            m.pillHeight = pillFrame.size.height;
            m.leading = iconFrame.origin.x;
            m.iconSize = iconFrame.size.width;
            m.gap = textFrame.origin.x - CGRectGetMaxX(iconFrame);
            m.trailing = pillFrame.size.width - CGRectGetMaxX(textFrame);
            m.itemGap = cellFrame.size.width - (pillOrigin.x + pillFrame.size.width);
            BOOL sane = m.pillHeight <= m.cellHeight && m.leading >= 0 && m.gap >= 0 &&
                        m.trailing >= 0 && m.itemGap >= 0 && m.iconSize <= m.pillHeight;
            style.metrics = sane ? m : fallback.metrics;
            style.measured = sane;
        } else {
            style.metrics = fallback.metrics;
        }
        if (!NBZColorIsVisible(style.fill)) style.fill = fallback.fill;
        if (style.cornerRadius <= 1) style.cornerRadius = style.metrics.pillHeight / 2.0;
        return style;
    }
    return fallback;
}

static UIImage *NBZBlockIcon(CGFloat side, UIColor *color) {
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:side * 0.75 weight:UIImageSymbolWeightSemibold];
    UIImage *symbol = [UIImage systemImageNamed:@"hand.raised" withConfiguration:config];
    if (!symbol) return nil;
    symbol = [symbol imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        // Native icons are 24pt boxes whose glyph is ~20pt tall with ~2pt
        // strokes. A symbol image carries its own padding (~20% of its
        // height), so fitting the image to the full box lands the glyph at
        // that size. Centred, never stretched.
        CGFloat box = side;
        CGSize s = symbol.size;
        CGFloat scale = MIN(box / s.width, box / s.height);
        CGSize fitted = CGSizeMake(s.width * scale, s.height * scale);
        [symbol drawInRect:CGRectMake((side - fitted.width) / 2.0, (side - fitted.height) / 2.0,
                                      fitted.width, fitted.height)];
    }];
}

#pragma mark - Our node classes (runtime subclasses of the app's Texture classes)

// ASCellNode subclass: fixed size, manual layout, and a forwarding net so an
// ELM-only message sent to every cell of the row (an `ELMCellNode` selector we
// do not implement) is logged and answered with nil instead of aborting.
static Class NBZCellNodeClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class base = NSClassFromString(@"ASCellNode");
        if (!base) return;
        Class c = objc_allocateClassPair(base, "NBZBlockCellNode", 0);
        if (!c) { cls = NSClassFromString(@"NBZBlockCellNode"); return; }

        SEL fits = NSSelectorFromString(@"calculateSizeThatFits:");
        class_addMethod(c, fits, imp_implementationWithBlock(^CGSize(id self, CGSize constrained) {
            NSValue *size = objc_getAssociatedObject(self, &kNBZCellSizeKey);
            return size ? size.CGSizeValue : CGSizeZero;
        }), "{CGSize=dd}32@0:8{CGSize=dd}16");

        SEL layout = NSSelectorFromString(@"layout");
        class_addMethod(c, layout, imp_implementationWithBlock(^(id self) {
            IMP up = class_getMethodImplementation(base, layout);
            if (up) ((void (*)(id, SEL))up)(self, layout);
            id pill = objc_getAssociatedObject(self, &kNBZPillKey);
            NSValue *frame = objc_getAssociatedObject(self, &kNBZPillFrameKey);
            if (pill && frame) NBZSetFrame(pill, frame.CGRectValue);
        }), "v16@0:8");

        SEL sigSel = @selector(methodSignatureForSelector:);
        class_addMethod(c, sigSel, imp_implementationWithBlock(^NSMethodSignature *(id self, SEL wanted) {
            IMP up = class_getMethodImplementation(base, sigSel);
            NSMethodSignature *sig = ((NSMethodSignature *(*)(id, SEL, SEL))up)(self, sigSel, wanted);
            if (sig) return sig;
            NBZLog(@"action bar: swallowed -[NBZBlockCellNode %@]", NSStringFromSelector(wanted));
            return [NSMethodSignature signatureWithObjCTypes:"@@:"];
        }), "@24@0:8:16");

        class_addMethod(c, @selector(forwardInvocation:), imp_implementationWithBlock(^(id self, NSInvocation *inv) {
            NSUInteger length = inv.methodSignature.methodReturnLength;
            if (length > 0 && length <= 16) {
                uint8_t zero[16] = {0};
                [inv setReturnValue:zero];
            }
        }), "v24@0:8@16");

        objc_registerClassPair(c);
        cls = c;
    });
    return cls;
}

// ASControlNode subclass for the pill: real touch tracking (highlight while the
// finger is down, TouchUpInside to fire), like any other control in the row.
static Class NBZPillNodeClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class base = NSClassFromString(@"ASControlNode");
        if (!base) return;
        Class c = objc_allocateClassPair(base, "NBZBlockPillNode", 0);
        if (!c) { cls = NSClassFromString(@"NBZBlockPillNode"); return; }
        SEL setHighlighted = @selector(setHighlighted:);
        class_addMethod(c, setHighlighted, imp_implementationWithBlock(^(id self, BOOL highlighted) {
            IMP up = class_getMethodImplementation(base, setHighlighted);
            if (up) ((void (*)(id, SEL, BOOL))up)(self, setHighlighted, highlighted);
            UIColor *fill = objc_getAssociatedObject(self, &kNBZPillFillKey);
            if (!fill) return;
            CGFloat alpha = NBZColorAlpha(fill);
            UIColor *shown = highlighted ? [fill colorWithAlphaComponent:MIN(1.0, alpha * 2.0)] : fill;
            NBZSetObject(self, @selector(setBackgroundColor:), shown);
        }), "v20@0:8B16");
        objc_registerClassPair(c);
        cls = c;
    });
    return cls;
}

static id NBZMakeBlockCellNode(NBZPillStyle *style) {
    Class cellClass = NBZCellNodeClass();
    Class pillClass = NBZPillNodeClass();
    Class textClass = NSClassFromString(@"ASTextNode");
    Class imageClass = NSClassFromString(@"ASImageNode");
    if (!cellClass || !pillClass || !textClass || !imageClass) {
        NBZLog(@"action bar: Texture classes missing");
        return nil;
    }
    NBZPillMetrics m = style.metrics;
    NSAttributedString *title = [[NSAttributedString alloc] initWithString:@"Block" attributes:style.textAttributes];
    CGRect textBounds = [title boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                            options:NSStringDrawingUsesLineFragmentOrigin
                                            context:nil];
    CGFloat textWidth = ceil(textBounds.size.width);
    CGFloat textHeight = ceil(textBounds.size.height);
    CGFloat pillWidth = m.leading + m.iconSize + m.gap + textWidth + m.trailing;
    UIColor *textColor = style.textAttributes[NSForegroundColorAttributeName] ?: UIColor.whiteColor;

    id cell = [[cellClass alloc] init];
    id pill = [[pillClass alloc] init];
    id icon = [[imageClass alloc] init];
    id text = [[textClass alloc] init];

    NBZNodeSetBool(icon, @selector(setLayerBacked:), YES);
    NBZNodeSetBool(text, @selector(setLayerBacked:), YES);
    NBZSetObject(icon, @selector(setImage:), NBZBlockIcon(m.iconSize, textColor));
    NBZSetObject(text, @selector(setAttributedText:), title);
    NBZSetFrame(icon, CGRectMake(m.leading, (m.pillHeight - m.iconSize) / 2.0, m.iconSize, m.iconSize));
    NBZSetFrame(text, CGRectMake(m.leading + m.iconSize + m.gap, (m.pillHeight - textHeight) / 2.0,
                                 textWidth, textHeight));

    objc_setAssociatedObject(pill, &kNBZPillFillKey, style.fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NBZSetObject(pill, @selector(setBackgroundColor:), style.fill);
    NBZSetFloat(pill, @selector(setCornerRadius:), style.cornerRadius);
    NBZNodeSetBool(pill, @selector(setIsAccessibilityElement:), YES);
    NBZSetObject(pill, @selector(setAccessibilityLabel:), @"Block artist");
    NBZSetObject(pill, @selector(setAccessibilityHint:), @"Blocks this artist and skips the track");
    if ([pill respondsToSelector:@selector(setAccessibilityTraits:)]) {
        ((void (*)(id, SEL, UIAccessibilityTraits))objc_msgSend)(pill, @selector(setAccessibilityTraits:),
                                                                  UIAccessibilityTraitButton);
    }
    SEL addTarget = NSSelectorFromString(@"addTarget:action:forControlEvents:");
    if ([pill respondsToSelector:addTarget]) {
        ((void (*)(id, SEL, id, SEL, NSUInteger))objc_msgSend)(pill, addTarget, [NBZPlayerUI shared],
            @selector(actionBarBlockTapped:), kNBZControlEventTouchUpInside);
    }
    NBZSetObject(pill, NSSelectorFromString(@"addSubnode:"), icon);
    NBZSetObject(pill, NSSelectorFromString(@"addSubnode:"), text);

    CGRect pillFrame = CGRectMake(0, m.pillY, pillWidth, m.pillHeight);
    NBZSetFrame(pill, pillFrame);
    NBZSetObject(cell, NSSelectorFromString(@"addSubnode:"), pill);
    objc_setAssociatedObject(cell, &kNBZPillKey, pill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kNBZPillFrameKey, [NSValue valueWithCGRect:pillFrame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kNBZCellSizeKey,
                             [NSValue valueWithCGSize:CGSizeMake(pillWidth + m.itemGap, m.cellHeight)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NBZLog(@"action bar: built Block cell %.0fx%.0f (pill %.0f, style %@)", pillWidth + m.itemGap,
           m.cellHeight, pillWidth, style.measured ? @"measured" : @"fallback");
    return cell;
}

#pragma mark - Section controller

static BOOL NBZIsActionBarController(id controller) {
    id collectionNode = NBZIvarObject(controller, "_collectionNode");
    if (![collectionNode respondsToSelector:@selector(accessibilityIdentifier)]) return NO;
    NSString *identifier = [collectionNode accessibilityIdentifier];
    return [identifier isKindOfClass:[NSString class]] && [identifier isEqualToString:kNBZActionBarID];
}

// Puts our node into (or takes it out of) the controller's own node list.
// Called only from inside the controller's view-model pass, i.e. inside the
// IGListKit batch where the item count is allowed to change.
static void NBZSyncBlockNode(id controller) {
    if (!NSThread.isMainThread) return;
    if (NBZIvarBool(controller, "_lazyMaterializeCellMode", YES)) return;  // count comes from _controllers then
    NSMutableArray *nodes = NBZIvarObject(controller, "_cellNodes");
    if (![nodes isKindOfClass:[NSMutableArray class]]) return;

    id node = objc_getAssociatedObject(controller, &kNBZBlockNodeKey);
    NSUInteger index = node ? [nodes indexOfObjectIdenticalTo:node] : NSNotFound;
    BOOL wanted = NBZBool(NBZKeyBlockEnabled, YES);

    if (!wanted) {
        if (index != NSNotFound) [nodes removeObjectAtIndex:index];
        return;
    }
    if (index != NSNotFound || nodes.count == 0) return;
    if (!node) {
        node = NBZMakeBlockCellNode(NBZStyleFromNativeNodes(nodes));
        if (!node) return;
        objc_setAssociatedObject(controller, &kNBZBlockNodeKey, node, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Right after the like/dislike pill.
    [nodes insertObject:node atIndex:MIN((NSUInteger)1, nodes.count)];
}

static id NBZControllerForRow(UICollectionView *row) {
    id controller = gNBZActionBarController;
    if (controller) {
        id collectionNode = NBZIvarObject(controller, "_collectionNode");
        if ([collectionNode respondsToSelector:@selector(isNodeLoaded)] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(collectionNode, @selector(isNodeLoaded)) &&
            NBZGet(collectionNode, @selector(view)) == row) {
            return controller;
        }
    }
    @try {
        id adapter = [(NSObject *)row.dataSource valueForKey:@"_listAdapter"];
        SEL forSection = NSSelectorFromString(@"sectionControllerForSection:");
        if (![adapter respondsToSelector:forSection]) return nil;
        controller = ((id (*)(id, SEL, NSInteger))objc_msgSend)(adapter, forSection, 0);
    } @catch (__unused NSException *e) {
        return nil;
    }
    Class elm = NSClassFromString(@"ELMCollectionNodeSingleSectionController");
    if (!elm || ![controller isKindOfClass:elm] || !NBZIsActionBarController(controller)) return nil;
    gNBZActionBarController = controller;
    return controller;
}

// The row can be built before its node carries the identifier, in which case
// the first view-model pass missed it. Ask the controller to run its own
// update once more; the view-model hook then adds the node.
static void NBZEnsureRowHasBlockNode(UICollectionView *row) {
    if (!NBZBool(NBZKeyBlockEnabled, YES)) return;
    id controller = NBZControllerForRow(row);
    if (!controller) return;
    NSArray *nodes = NBZIvarObject(controller, "_cellNodes");
    id node = objc_getAssociatedObject(controller, &kNBZBlockNodeKey);
    if (node && [nodes indexOfObjectIdenticalTo:node] != NSNotFound) return;
    if (NBZIvarBool(controller, "_updateInProgress", NO)) return;

    NSInteger tries = [objc_getAssociatedObject(controller, &kNBZRefreshTriesKey) integerValue];
    if (tries >= 3) return;
    objc_setAssociatedObject(controller, &kNBZRefreshTriesKey, @(tries + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak id weakController = controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        id strong = weakController;
        if (![strong respondsToSelector:@selector(update)]) return;
        NBZLog(@"action bar: asking row to update (try %ld)", (long)tries + 1);
        ((void (*)(id, SEL))objc_msgSend)(strong, @selector(update));
    });
}

void NBZRefreshActionBar(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id controller = gNBZActionBarController;
        if (!controller || ![controller respondsToSelector:@selector(update)]) return;
        objc_setAssociatedObject(controller, &kNBZRefreshTriesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL))objc_msgSend)(controller, @selector(update));
    });
}

#pragma mark - Hooks

void NBZInstallActionBarHooks(void) {
    Class controllerClass = NSClassFromString(@"ELMCollectionNodeSingleSectionController");
    SEL viewModels = NSSelectorFromString(@"sectionController:viewModelsForObject:");
    Method method = controllerClass ? class_getInstanceMethod(controllerClass, viewModels) : NULL;
    if (!method || !NBZCellNodeClass() || !NBZPillNodeClass()) {
        NBZLog(@"action bar: required classes missing, Block pill disabled");
        return;
    }
    // Owned by this class (checked on device), so this patches nothing else.
    nbz_orig_viewModels = method_setImplementation(method,
        imp_implementationWithBlock(^id(id self, id sectionController, id object) {
            if (NBZIsActionBarController(self)) {
                gNBZActionBarController = self;
                NBZSyncBlockNode(self);
            }
            return ((id (*)(id, SEL, id, id))nbz_orig_viewModels)(self, viewModels, sectionController, object);
        }));

    Class collectionView = NSClassFromString(@"ASCollectionView");
    Method layout = collectionView ? class_getInstanceMethod(collectionView, @selector(layoutSubviews)) : NULL;
    if (layout) {
        IMP replacement = imp_implementationWithBlock(^(UICollectionView *self) {
            ((void (*)(id, SEL))nbz_orig_rowLayout)(self, @selector(layoutSubviews));
            if ([self.accessibilityIdentifier isEqualToString:kNBZActionBarID]) NBZEnsureRowHasBlockNode(self);
        });
        nbz_orig_rowLayout = method_getImplementation(layout);
        if (!class_addMethod(collectionView, @selector(layoutSubviews), replacement, method_getTypeEncoding(layout))) {
            method_setImplementation(layout, replacement);
        }
    }

    [[NSNotificationCenter defaultCenter] addObserverForName:NBZDefaultsDidChangeNotification object:nil
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(__unused NSNotification *note) {
        NBZRefreshActionBar();
    }];
    NBZLog(@"action bar: hooks installed");
}
