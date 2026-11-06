#import "AppKit.h"
#include <unistd.h>
// Launch Services for one app on iPadOS: the guest is the only application
// running, and no other application is installed to find, open or launch.
// A launcher hand-off (WoW asks for the Battle.net app, then quits when
// sharedWorkspace is nil) needs these answers instead of stub nils.
NSString *const NSWorkspaceDidWakeNotification=@"NSWorkspaceDidWakeNotification";
NSString *const NSWorkspaceWillSleepNotification=@"NSWorkspaceWillSleepNotification";
NSString *const NSWorkspaceLaunchConfigurationArguments=@"NSWorkspaceLaunchConfigurationArguments";

// The guest's own bundle: the .app in the working directory the launcher set
// (NSBundle.mainBundle answers the guest only when the guest itself asks).
static NSBundle *guest_bundle(void) {
    static NSBundle *bundle; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *directory=NSFileManager.defaultManager.currentDirectoryPath;
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL])
            if ([name.pathExtension isEqual:@"app"]) { bundle=[NSBundle bundleWithPath:[directory stringByAppendingPathComponent:name]]; break; }
        AKLog(@"running application: %@",bundle.bundleIdentifier?:@"(no bundle in the working directory)");
    });
    return bundle;
}
static NSError *not_installed(NSURL *url) {
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:url?@{NSURLErrorKey:url}:nil];
}

@interface NSRunningApplication : AKStubObject
+ (NSRunningApplication *)currentApplication;
@property(readonly) NSString *bundleIdentifier;
@end
@implementation NSRunningApplication
+ (NSRunningApplication *)currentApplication { static NSRunningApplication *s; static dispatch_once_t once; dispatch_once(&once, ^{s=[self new];}); return s; }
+ (NSArray *)runningApplicationsWithBundleIdentifier:(NSString *)identifier {
    BOOL own=identifier && [identifier isEqual:self.currentApplication.bundleIdentifier];
    AKLog(@"running applications with bundle identifier %@: %@ (asked from %p)",identifier,own?@"this app":@"none",__builtin_return_address(0));
    return own?@[self.currentApplication]:@[];
}
+ (instancetype)runningApplicationWithProcessIdentifier:(pid_t)pid { return pid==getpid()?self.currentApplication:nil; }
- (pid_t)processIdentifier { return getpid(); }
- (NSString *)bundleIdentifier { return guest_bundle().bundleIdentifier; }
- (NSURL *)bundleURL { return guest_bundle().bundleURL; }
- (NSURL *)executableURL { return guest_bundle().executableURL; }
- (NSString *)localizedName { return [guest_bundle() objectForInfoDictionaryKey:@"CFBundleName"]; }
- (NSInteger)activationPolicy { return 0; }   // NSApplicationActivationPolicyRegular
- (BOOL)isActive { return YES; }
- (BOOL)isHidden { return NO; }
- (BOOL)isFinishedLaunching { return YES; }
- (BOOL)isTerminated { return NO; }
- (BOOL)activateWithOptions:(NSUInteger)options { (void)options; return YES; }
- (BOOL)activate { return YES; }
- (BOOL)hide { return NO; }
- (BOOL)unhide { return NO; }
- (BOOL)terminate { return NO; }
- (BOOL)forceTerminate { return NO; }
@end

@interface NSWorkspace : AKStubObject
@end
@implementation NSWorkspace { NSNotificationCenter *_center; }
+ (NSWorkspace *)sharedWorkspace { static NSWorkspace *s; static dispatch_once_t once; dispatch_once(&once, ^{s=[self new];}); return s; }
- (instancetype)init { if ((self=[super init])) _center=[NSNotificationCenter new]; return self; }
// Sleep and wake are never posted: iPadOS suspends the whole app instead.
- (NSNotificationCenter *)notificationCenter { return _center; }
- (NSArray *)runningApplications { return @[NSRunningApplication.currentApplication]; }
- (NSRunningApplication *)frontmostApplication { return NSRunningApplication.currentApplication; }
- (NSRunningApplication *)menuBarOwningApplication { return NSRunningApplication.currentApplication; }
- (NSURL *)URLForApplicationWithBundleIdentifier:(NSString *)identifier {
    AKLog(@"no application installed with bundle identifier %@",identifier); return nil;
}
- (NSArray *)URLsForApplicationsWithBundleIdentifier:(NSString *)identifier {
    AKLog(@"no application installed with bundle identifier %@",identifier); return @[];
}
- (NSString *)absolutePathForAppBundleWithIdentifier:(NSString *)identifier {
    AKLog(@"no application installed with bundle identifier %@",identifier); return nil;
}
- (NSString *)fullPathForApplication:(NSString *)name { AKLog(@"no application installed named %@",name); return nil; }
- (BOOL)openURL:(NSURL *)url { AKLog(@"nothing can open %@",url); return NO; }
// As on macOS, the handler runs on a concurrent queue.
- (void)openURL:(NSURL *)url configuration:(id)configuration completionHandler:(void (^)(NSRunningApplication *, NSError *))handler {
    (void)configuration; AKLog(@"nothing can open %@",url);
    if (handler) dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0), ^{ handler(nil,not_installed(url)); });
}
- (void)openApplicationAtURL:(NSURL *)url configuration:(id)configuration completionHandler:(void (^)(NSRunningApplication *, NSError *))handler {
    (void)configuration; AKLog(@"cannot launch the application at %@",url);
    if (handler) dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0), ^{ handler(nil,not_installed(url)); });
}
- (NSRunningApplication *)launchApplicationAtURL:(NSURL *)url options:(NSUInteger)options configuration:(NSDictionary *)configuration error:(NSError **)error {
    (void)options; (void)configuration; AKLog(@"cannot launch the application at %@",url);
    if (error) *error=not_installed(url);
    return nil;
}
- (BOOL)launchApplication:(NSString *)name { AKLog(@"cannot launch the application %@",name); return NO; }
- (BOOL)launchAppWithBundleIdentifier:(NSString *)identifier options:(NSUInteger)options additionalEventParamDescriptor:(id)descriptor launchIdentifier:(id *)launchIdentifier {
    (void)options; (void)descriptor; if (launchIdentifier) *launchIdentifier=nil;
    AKLog(@"cannot launch the application with bundle identifier %@",identifier); return NO;
}
- (BOOL)selectFile:(NSString *)path inFileViewerRootedAtPath:(NSString *)root { (void)root; AKLog(@"no file viewer to show %@",path); return NO; }
- (void)activateFileViewerSelectingURLs:(NSArray *)urls { AKLog(@"no file viewer to show %@",urls); }
@end
