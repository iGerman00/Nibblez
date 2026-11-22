#import "NBZSideload.h"
#import "NBZUtil.h"
#import <Security/Security.h>
#import <objc/runtime.h>

// The keychain group this signature really has: the group of an item we add
// ourselves lands in the app's first (default) group.
static NSString *NBZAccessGroup(void) {
    static NSString *group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: @"bundleSeedID",
            (__bridge id)kSecAttrService: @"",
            (__bridge id)kSecReturnAttributes: @YES,
        };
        CFDictionaryRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
        if (status == errSecItemNotFound) status = SecItemAdd((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
        if (status == errSecSuccess && result) {
            group = [(__bridge NSDictionary *)result objectForKey:(__bridge id)kSecAttrAccessGroup];
        }
        if (result) CFRelease(result);
        NBZLog(@"sideload: keychain group %@ (status %d)", group, (int)status);
    });
    return group;
}

static void NBZReplace(Class cls, SEL sel, id block) {
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    IMP imp = imp_implementationWithBlock(block);
    if (!class_addMethod(cls, sel, imp, method_getTypeEncoding(method))) method_setImplementation(method, imp);
}

// Replace a +/- accessGroup style getter on every Google keychain class.
static void NBZReplaceGroupGetter(NSString *className, NSString *selectorName) {
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(selectorName);
    id block = ^NSString *(id self) { return NBZAccessGroup(); };
    NBZReplace(object_getClass(cls), sel, block);  // class method
    NBZReplace(cls, sel, block);                   // instance method
}

void NBZInstallSideloadFixes(void) {
    // Re-signing changes the team ID in the keychain group. Many sideload
    // tools also strip embedded.mobileprovision, so this is the reliable test.
    NSString *group = NBZAccessGroup();
    if (!group.length || [group hasPrefix:@"EQHXZ8M8AV."]) return;
    NBZLog(@"sideload: re-signed build, redirecting keychain and app group");

    NBZReplaceGroupGetter(@"SSOKeychainCore", @"accessGroup");
    NBZReplaceGroupGetter(@"SSOKeychainCore", @"sharedAccessGroup");
    NBZReplaceGroupGetter(@"SSOKeychain", @"accessGroup");
    NBZReplaceGroupGetter(@"SSOKeychain", @"sharedAccessGroup");
    NBZReplaceGroupGetter(@"SSOKeychainHelper", @"accessGroup");
    NBZReplaceGroupGetter(@"SSOKeychainHelper", @"sharedAccessGroup");
    NBZReplaceGroupGetter(@"SSOFolsomKeychainUtils", @"sharedAccessGroup");

    // Firebase / GoogleUtilities keychain storage takes the group as an argument.
    Class gul = NSClassFromString(@"GULKeychainStorage");
    static IMP origGet, origSet, origRemove;
    SEL getSel = NSSelectorFromString(@"getObjectForKey:objectClass:accessGroup:completionHandler:");
    SEL setSel = NSSelectorFromString(@"setObject:forKey:accessGroup:completionHandler:");
    SEL removeSel = NSSelectorFromString(@"removeObjectForKey:accessGroup:completionHandler:");
    Method m;
    if ((m = class_getInstanceMethod(gul, getSel))) {
        origGet = method_getImplementation(m);
        NBZReplace(gul, getSel, ^id(id self, NSString *key, Class objectClass, NSString *group, id handler) {
            return ((id (*)(id, SEL, id, Class, id, id))origGet)(self, getSel, key, objectClass, NBZAccessGroup() ?: group, handler);
        });
    }
    if ((m = class_getInstanceMethod(gul, setSel))) {
        origSet = method_getImplementation(m);
        NBZReplace(gul, setSel, ^id(id self, id object, NSString *key, NSString *group, id handler) {
            return ((id (*)(id, SEL, id, id, id, id))origSet)(self, setSel, object, key, NBZAccessGroup() ?: group, handler);
        });
    }
    if ((m = class_getInstanceMethod(gul, removeSel))) {
        origRemove = method_getImplementation(m);
        NBZReplace(gul, removeSel, ^id(id self, NSString *key, NSString *group, id handler) {
            return ((id (*)(id, SEL, id, id, id))origRemove)(self, removeSel, key, NBZAccessGroup() ?: group, handler);
        });
    }

    // Without the app group entitlement this returns nil; point it at a folder
    // the app can write to.
    static IMP origContainer;
    SEL containerSel = @selector(containerURLForSecurityApplicationGroupIdentifier:);
    m = class_getInstanceMethod(NSFileManager.class, containerSel);
    if (m) {
        origContainer = method_getImplementation(m);
        NBZReplace(NSFileManager.class, containerSel, ^NSURL *(NSFileManager *self, NSString *identifier) {
            if (!identifier) return ((NSURL *(*)(id, SEL, id))origContainer)(self, containerSel, identifier);
            NSURL *docs = [[self URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
            NSURL *url = [docs URLByAppendingPathComponent:@"AppGroup"];
            [self createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:nil];
            return url;
        });
    }
}
