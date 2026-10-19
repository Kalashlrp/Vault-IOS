// Copyright (c) 2025 Project Nova LLC

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
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
#define FN_COMMON_INPUT_SETTINGS_CLASS  0x107497f68 // cached UClass* of UCommonInputSettings
#define FN_COMMON_INPUT_SUBSYSTEM_CLASS 0x107437c40 // cached UClass* of UCommonInputSubsystem
#define FN_CLIENT_SETTINGS_RECORD_CLASS 0x107494ce8 // cached UClass* of UFortClientSettingsRecord
#define FN_PLATFORM_APPLICATION     0x107527438 // FSlateApplicationBase::PlatformApplication (TSharedPtr)
#define FN_IOS_APPLICATION_VTABLE   0x10577c678
#define FN_IOS_INPUT_VTABLE         0x10560df60
#define FN_GUOBJECTARRAY            0x1076719b0

#define GUOBJECTARRAY_OBJECTS       0x10 // FChunkedFixedUObjectArray::Objects (FUObjectItem**)
#define GUOBJECTARRAY_NUM_ELEMENTS  0x24
#define UOBJECT_ITEM_SIZE           0x18
#define UOBJECT_CHUNK_SIZE          0x10000
#define UOBJECT_FLAGS               0x08
#define UOBJECT_CLASS               0x10
#define RF_CLASS_DEFAULT_OBJECT     0x10

#define UCLASS_DEFAULT_OBJECT       0xf8
#define RUNTIME_OPTIONS_PROCESS_GAMEPAD_ON_MOBILE 0x25d // bProcessGamepadInputOnMobile
#define IOS_APPLICATION_INPUT       0x70  // FIOSApplication::InputInterface
#define IOS_INPUT_ALLOW_CONTROLLERS 0xe4  // FIOSInputInterface::bAllowControllers
#define COMMON_INPUT_SETTINGS_PLATFORM 0x180 // UCommonInputSettings::CurrentPlatform (FCommonInputPlatformData)
#define PLATFORM_DATA_SUPPORTS_GAMEPAD 0x3   // FCommonInputPlatformData::bSupportsGamepad
#define CLIENT_SETTINGS_IGNORE_GAMEPAD 0x418 // UFortClientSettingsRecord::bIgnoreGamepadInput

// Values as the game had them before they were forced (-1 = not seen yet), shown by the test alert.
static struct {
    int processGamepadOnMobile;
    int allowControllers;
    int platformSupportsGamepad;
    int ignoreGamepadInput;
    int subsystemCount;
    uint8_t subsystemState[5]; // UCommonInputSubsystem bytes 0x58, 0x59, 0x5a, 0xb0, 0xb1
    int objectCount;
} Diagnostics = { -1, -1, -1, -1, 0, { 0 }, 0 };

static intptr_t Slide;

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

static void ForceByte(uint8_t *address, uint8_t value, int *initial)
{
    if (*initial < 0) {
        *initial = *address;
    }
    if (*address != value) {
        *address = value;
    }
}

static void ApplyGlobals(void)
{
    void *runtimeOptionsClass = ReadPointer(FN_RUNTIME_OPTIONS_CLASS + Slide);
    if (runtimeOptionsClass) {
        uint8_t *runtimeOptions = (uint8_t *)ReadPointer((uintptr_t)runtimeOptionsClass + UCLASS_DEFAULT_OBJECT);
        if (runtimeOptions) {
            ForceByte(runtimeOptions + RUNTIME_OPTIONS_PROCESS_GAMEPAD_ON_MOBILE, 1, &Diagnostics.processGamepadOnMobile);
        }
    }

    void *application = ReadPointer(FN_PLATFORM_APPLICATION + Slide);
    if (application && (uintptr_t)ReadPointer((uintptr_t)application) == FN_IOS_APPLICATION_VTABLE + Slide) {
        uint8_t *input = (uint8_t *)ReadPointer((uintptr_t)application + IOS_APPLICATION_INPUT);
        if (input && (uintptr_t)ReadPointer((uintptr_t)input) == FN_IOS_INPUT_VTABLE + Slide) {
            ForceByte(input + IOS_INPUT_ALLOW_CONTROLLERS, 1, &Diagnostics.allowControllers);
        }
    }
}

// Walks GUObjectArray for the per-player objects that have no global pointer.
static void ApplyObjects(void)
{
    uint8_t **chunks = (uint8_t **)ReadPointer(FN_GUOBJECTARRAY + Slide + GUOBJECTARRAY_OBJECTS);
    int32_t count = *(volatile int32_t *)(FN_GUOBJECTARRAY + Slide + GUOBJECTARRAY_NUM_ELEMENTS);
    if (!chunks || count <= 0 || count > 16 * UOBJECT_CHUNK_SIZE) {
        return;
    }

    void *settingsClass = ReadPointer(FN_COMMON_INPUT_SETTINGS_CLASS + Slide);
    void *subsystemClass = ReadPointer(FN_COMMON_INPUT_SUBSYSTEM_CLASS + Slide);
    void *recordClass = ReadPointer(FN_CLIENT_SETTINGS_RECORD_CLASS + Slide);
    int subsystems = 0;

    for (int32_t i = 0; i < count; i++) {
        uint8_t *chunk = chunks[i / UOBJECT_CHUNK_SIZE];
        if (!chunk) {
            i = (i / UOBJECT_CHUNK_SIZE + 1) * UOBJECT_CHUNK_SIZE - 1;
            continue;
        }
        uint8_t *object = (uint8_t *)ReadPointer((uintptr_t)(chunk + (i % UOBJECT_CHUNK_SIZE) * UOBJECT_ITEM_SIZE));
        if (!object) {
            continue;
        }
        void *objectClass = ReadPointer((uintptr_t)(object + UOBJECT_CLASS));
        BOOL isDefault = (*(volatile uint32_t *)(object + UOBJECT_FLAGS) & RF_CLASS_DEFAULT_OBJECT) != 0;

        if (settingsClass && objectClass == settingsClass) {
            ForceByte(object + COMMON_INPUT_SETTINGS_PLATFORM + PLATFORM_DATA_SUPPORTS_GAMEPAD, 1, &Diagnostics.platformSupportsGamepad);
        } else if (recordClass && objectClass == recordClass && !isDefault) {
            ForceByte(object + CLIENT_SETTINGS_IGNORE_GAMEPAD, 0, &Diagnostics.ignoreGamepadInput);
        } else if (subsystemClass && objectClass == subsystemClass && !isDefault) {
            static const int offsets[5] = { 0x58, 0x59, 0x5a, 0xb0, 0xb1 };
            for (int j = 0; j < 5; j++) {
                Diagnostics.subsystemState[j] = object[offsets[j]];
            }
            subsystems++;
        }
    }
    Diagnostics.subsystemCount = subsystems;
    Diagnostics.objectCount = count;
}

static void *ControllerSupportThread(void *arg)
{
    // Keep re-applying: config loads, backend hotfixes and cloud settings rewrite these values at any time.
    for (unsigned tick = 0;; tick++) {
        ApplyGlobals();
        // The object walk is heavier: every 5 s for the first 3 minutes, then every 30 s.
        if (tick % (tick < 360 ? 10 : 60) == 0) {
            ApplyObjects();
        }
        usleep(500000);
    }
    return NULL;
}

static NSString *DescribeValue(int value)
{
    return value < 0 ? @"nicht gefunden" : [NSString stringWithFormat:@"%d", value];
}

// Test build only: shows what the game had set, so the remaining blocker can be identified.
static void ShowDiagnostics(NSString *reason)
{
    NSMutableString *text = [NSMutableString stringWithFormat:@"%@\n\n", reason];
    [text appendFormat:@"ProcessGamepadOnMobile vorher: %@\n", DescribeValue(Diagnostics.processGamepadOnMobile)];
    [text appendFormat:@"AllowControllers (ini) vorher: %@\n", DescribeValue(Diagnostics.allowControllers)];
    [text appendFormat:@"Platform SupportsGamepad vorher: %@\n", DescribeValue(Diagnostics.platformSupportsGamepad)];
    [text appendFormat:@"IgnoreGamepadInput vorher: %@\n", DescribeValue(Diagnostics.ignoreGamepadInput)];
    [text appendFormat:@"InputSubsystem: %d, Werte %d %d %d %d %d\n", Diagnostics.subsystemCount,
        Diagnostics.subsystemState[0], Diagnostics.subsystemState[1], Diagnostics.subsystemState[2],
        Diagnostics.subsystemState[3], Diagnostics.subsystemState[4]];
    [text appendFormat:@"Objekte: %d\n", Diagnostics.objectCount];

    Class controllerClass = NSClassFromString(@"GCController");
    NSArray *controllers = controllerClass ? [controllerClass performSelector:@selector(controllers)] : nil;
    [text appendFormat:@"\nController: %lu\n", (unsigned long)controllers.count];
    for (id controller in controllers) {
        [text appendFormat:@"- %@, extended: %@\n", [controller valueForKey:@"vendorName"],
            [controller valueForKey:@"extendedGamepad"] ? @"ja" : @"nein"];
    }

    UIWindow *window = nil;
    for (UIWindow *candidate in [UIApplication sharedApplication].windows) {
        if (candidate.isKeyWindow) {
            window = candidate;
            break;
        }
    }
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    if (!top || [top isKindOfClass:[UIAlertController class]]) {
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Sinum Controller Test"
                                                                   message:text
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

static void StartControllerSupport(void)
{
    if (!GetExecutableSlide(&Slide) || !IsSupportedBuild(Slide)) {
        NSLog(@"[Sinum] Unknown FortniteClient build, controller support disabled");
        return;
    }

    pthread_t thread;
    if (pthread_create(&thread, NULL, ControllerSupportThread, NULL) == 0) {
        pthread_detach(thread);
    }

    [[NSNotificationCenter defaultCenter] addObserverForName:@"GCControllerDidConnectNotification"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            ShowDiagnostics(@"Controller verbunden");
        });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        ShowDiagnostics(@"90 Sekunden nach Start");
    });
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
