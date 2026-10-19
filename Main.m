// Copyright (c) 2025 Project Nova LLC

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <pthread.h>
#import <string.h>
#import <unistd.h>

#define API_URL @"http://94.249.167.201:3551"
#define EPIC_GAMES_URL @"ol.epicgames.com"

// Controller support for FortniteClient 8.51 (CL 6165369), applied at runtime.
// The executable must stay unmodified (its integrity check kills the app after any patch),
// so only heap objects are written here, never code or image data.
// All addresses are unslid VAs from that exact build.
#define FN_STATIC_CLASS_FN          0x1029f9708 // UFortRuntimeOptions::StaticClass, used to verify the build
#define FN_RUNTIME_OPTIONS_CLASS    0x1074a02e8 // cached UClass* of UFortRuntimeOptions
#define FN_PLATFORM_APPLICATION     0x107527438 // FSlateApplicationBase::PlatformApplication (TSharedPtr)
#define FN_IOS_APPLICATION_VTABLE   0x10577c678
#define FN_IOS_INPUT_VTABLE         0x10560df60

#define UCLASS_DEFAULT_OBJECT       0xf8
#define RUNTIME_OPTIONS_PROCESS_GAMEPAD_ON_MOBILE 0x25d // bProcessGamepadInputOnMobile
#define IOS_APPLICATION_INPUT       0x70  // FIOSApplication::InputInterface
#define IOS_INPUT_ALLOW_CONTROLLERS 0xe4  // FIOSInputInterface::bAllowControllers

static BOOL GetExecutableSlide(intptr_t *slide)
{
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if (header && header->filetype == MH_EXECUTE) {
            *slide = _dyld_get_image_vmaddr_slide(i);
            return YES;
        }
    }
    return NO;
}

static BOOL IsSupportedBuild(intptr_t slide)
{
    static const uint32_t expected[4] = { 0xf0025528, 0xf9417500, 0xb4000040, 0xd65f03c0 };
    return memcmp((const void *)(FN_STATIC_CLASS_FN + slide), expected, sizeof(expected)) == 0;
}

static void *ReadPointer(uintptr_t address)
{
    return *(void * volatile *)address;
}

static void *ControllerSupportThread(void *arg)
{
    intptr_t slide = (intptr_t)arg;
    BOOL loggedRuntimeOptions = NO, loggedInput = NO;

    // Keep re-applying: config loads and backend hotfixes rewrite these values at any time.
    for (;;) {
        void *runtimeOptionsClass = ReadPointer(FN_RUNTIME_OPTIONS_CLASS + slide);
        if (runtimeOptionsClass) {
            uint8_t *runtimeOptions = (uint8_t *)ReadPointer((uintptr_t)runtimeOptionsClass + UCLASS_DEFAULT_OBJECT);
            if (runtimeOptions && runtimeOptions[RUNTIME_OPTIONS_PROCESS_GAMEPAD_ON_MOBILE] != 1) {
                runtimeOptions[RUNTIME_OPTIONS_PROCESS_GAMEPAD_ON_MOBILE] = 1;
                if (!loggedRuntimeOptions) {
                    NSLog(@"[Sinum] bProcessGamepadInputOnMobile forced on");
                    loggedRuntimeOptions = YES;
                }
            }
        }

        void *application = ReadPointer(FN_PLATFORM_APPLICATION + slide);
        if (application && (uintptr_t)ReadPointer((uintptr_t)application) == FN_IOS_APPLICATION_VTABLE + slide) {
            uint8_t *input = (uint8_t *)ReadPointer((uintptr_t)application + IOS_APPLICATION_INPUT);
            if (input && (uintptr_t)ReadPointer((uintptr_t)input) == FN_IOS_INPUT_VTABLE + slide
                && input[IOS_INPUT_ALLOW_CONTROLLERS] != 1) {
                input[IOS_INPUT_ALLOW_CONTROLLERS] = 1;
                if (!loggedInput) {
                    NSLog(@"[Sinum] bAllowControllers forced on");
                    loggedInput = YES;
                }
            }
        }

        usleep(500000);
    }
    return NULL;
}

static void StartControllerSupport(void)
{
    intptr_t slide = 0;
    if (!GetExecutableSlide(&slide) || !IsSupportedBuild(slide)) {
        NSLog(@"[Sinum] Unknown FortniteClient build, controller support disabled");
        return;
    }

    pthread_t thread;
    if (pthread_create(&thread, NULL, ControllerSupportThread, (void *)slide) == 0) {
        pthread_detach(thread);
    }
}

@interface CustomURLProtocol : NSURLProtocol
@end

@implementation CustomURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    NSString *absoluteURLString = [[request URL] absoluteString];
    if ([absoluteURLString containsString:EPIC_GAMES_URL] && ![absoluteURLString containsString:@"/CloudDir/"]) {
        if ([NSURLProtocol propertyForKey:@"Handled" inRequest:request]) {
            return NO;
        }
        return YES;
    }
    return NO;
}

+ (NSURLRequest*)canonicalRequestForRequest:(NSURLRequest*)request
{
    return request;
}

- (void)startLoading
{
    NSMutableURLRequest* modifiedRequest = [[self request] mutableCopy];

    NSString* originalPath = [modifiedRequest.URL path];
    NSString* newBaseURLString = API_URL;

    NSURLComponents* components = [NSURLComponents componentsWithString:newBaseURLString];
    components.path = originalPath;

    NSURLComponents *originalComponents = [NSURLComponents componentsWithURL:modifiedRequest.URL resolvingAgainstBaseURL:NO];
    if (originalComponents.queryItems.count > 0) {
        NSMutableArray<NSURLQueryItem *> *cleanItems = [NSMutableArray array];
        for (NSURLQueryItem *item in originalComponents.queryItems) {
            NSString *decodedValue = item.value ? [item.value stringByRemovingPercentEncoding] : nil;
            [cleanItems addObject:[NSURLQueryItem queryItemWithName:item.name value:decodedValue]];
        }
        components.queryItems = cleanItems;
    }

    [modifiedRequest setURL:components.URL];
    [NSURLProtocol setProperty:@YES forKey:@"Handled" inRequest:modifiedRequest];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    [[self client] URLProtocol:self
        wasRedirectedToRequest:modifiedRequest
              redirectResponse:nil];
#pragma clang diagnostic pop
}

- (void)stopLoading
{
}
@end

__attribute__((constructor)) void entry()
{
    [NSURLProtocol registerClass:[CustomURLProtocol class]];
    StartControllerSupport();
}
