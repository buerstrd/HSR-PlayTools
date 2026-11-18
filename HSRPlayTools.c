#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
/* Fixed addresses applied when UnityFramework loads. */
#include <stdint.h>
#define HSR_ENTRY 0xfed5bf0ULL
#define HSR_PC_MODE 0x253eae4ULL

#include "embedded_lua.h"

/* PlayCover loads this plugin. Fixed-address hooks affect private process memory;
 * game binaries on disk remain unchanged. Lua stays on its calling main thread. */
typedef struct lua_State lua_State;
typedef int (*PCall)(lua_State *, int, int, int);
static PCall original_pcall;
static _Thread_local bool entering;
static bool script_initialized;
static time_t last_init_failure;
static double initialization_not_before;
static char *startup_bytecode;
static size_t startup_bytecode_size;
static bool ready;
static void *unity_handle;
static int (*gettop)(lua_State *);
static void (*settop)(lua_State *, int);
static const char *(*tolstring)(lua_State *, int, size_t *);
static char *(*compile_source)(const char *, size_t, void *, size_t *);
static int (*load_chunk)(lua_State *, const char *, const char *, size_t, int);
static double (*tonumberx)(lua_State *, int, int *);
static void (*pushnumber)(lua_State *, double);
static void (*pushstring)(lua_State *, const char *);
static void (*pushclosure)(lua_State *, int (*)(lua_State *), const char *, int, void *);
static void (*setglobal)(lua_State *, const char *);
static void (*getfield)(lua_State *, int, const char *);
static int (*luatype)(lua_State *, int);
static const char *(*luatypename)(lua_State *, int);
static int last_ui_input_frame = -1;
static uintptr_t unity_slide;
typedef struct { int id, mode; double x, y, factor; } ScaleBaseline;
static ScaleBaseline baselines[4096];
static size_t baseline_count;

static int display_version(lua_State *L) {
    pushstring(L, HSR_DISPLAY_VERSION);
    return 1;
}

/* Process-wide originals survive changes of Lua environment and Lua VM. */
static int scale_baseline(lua_State *L) {
    int valid = 0;
    double input[5];
    for (int i = 0; i < 5; ++i) {
        input[i] = tonumberx(L, i + 1, &valid);
        if (!valid) return 0;
    }
    int id = (int)input[0], mode = (int)input[1];
    ScaleBaseline *found = NULL;
    for (size_t i = 0; i < baseline_count; ++i)
        if (baselines[i].id == id && baselines[i].mode == mode) { found = &baselines[i]; break; }
    if (!found) {
        if (baseline_count >= 4096) return 0;
        found = &baselines[baseline_count++];
        *found = (ScaleBaseline){id, mode, input[2], input[3], input[4]};
    }
    pushnumber(L, found->x); pushnumber(L, found->y); pushnumber(L, found->factor);
    return 3;
}

/* Runtime ARM64 hook. */
/* ARM64 fixed-address hook. Trampoline instructions are copied from memory. */
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>

static bool runtime_write(void *target, const void *source, size_t size) {
    uintptr_t page=(uintptr_t)getpagesize();
    uintptr_t first=(uintptr_t)target & ~(page-1);
    uintptr_t last=((uintptr_t)target+size+page-1) & ~(page-1);
    if (mach_vm_protect(mach_task_self(),first,last-first,false,
        VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)!=KERN_SUCCESS) return false;
    memcpy(target,source,size);
    kern_return_t result=mach_vm_protect(mach_task_self(),first,last-first,false,
        VM_PROT_READ|VM_PROT_EXECUTE);
    sys_icache_invalidate(target,size);
    return result==KERN_SUCCESS;
}
static void runtime_jump(void *out, uintptr_t destination) {
    const uint32_t branch[]={0x58000050,0xd61f0200}; // ldr x16,#8; br x16
    memcpy(out,branch,sizeof(branch));
    memcpy((unsigned char *)out+8,&destination,sizeof(destination));
}
static void *runtime_trampoline(const void *entry) {
    uint32_t instructions[4];
    memcpy(instructions,entry,sizeof(instructions));
    size_t size=(size_t)getpagesize();
    void *code=mmap(NULL,size,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    if (code==MAP_FAILED) return NULL;
    memcpy(code,instructions,sizeof(instructions));
    runtime_jump((unsigned char *)code+16,(uintptr_t)entry+16);
    if (mprotect(code,size,PROT_READ|PROT_EXEC)!=0) { munmap(code,size); return NULL; }
    sys_icache_invalidate(code,32);
    return code;
}

static unsigned long ui_left_press,ui_left_release;
/* Native keyboard and mouse bridge. */
/* Local AppKit events -> Unity's existing legacy-input icall slots.
 * Only this app receives events. No global input monitor or key logging. */
#include <objc/runtime.h>
#include <objc/message.h>
#include <CoreGraphics/CGGeometry.h>
#include <math.h>

typedef struct { float x, y; } HSRFloat2;
typedef struct { float x, y, z; } HSRFloat3;
static id mouse_monitor;
static bool mouse_bridge_active, mouse_position_valid;
static double mouse_pending_x, mouse_pending_y, mouse_pending_wx, mouse_pending_wy;
static double mouse_frame_x, mouse_frame_y, mouse_frame_wx, mouse_frame_wy;
static double mouse_window_x, mouse_window_y;
static double mouse_screen_width = 3840, mouse_screen_height = 2160;
static int mouse_frame = -1;
static bool (*original_cursor_visible)(void);
static int (*original_cursor_lock)(void);

static int (*unity_frame_count)(void);
static float (*original_axis_raw)(void *);
static float (*original_axis)(void *);
static void (*original_mouse_position)(HSRFloat3 *);
static void (*original_scroll_delta)(HSRFloat2 *);

/* Cursor capture and focus lifecycle. */
/* Focus-scoped macOS relative mouse capture for the iOS native PC controls. */
static void reset_input_keys(void);
static bool capture_requested, capture_active, capture_feature_enabled;
static bool capture_api_ready;
static bool capture_waits_for_alt=true;
static bool initial_world_capture_used;
static id game_system_cursor;
static bool system_cursor_enabled;
static double warp_motion_until;
static bool warp_motion_suppressed(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1e9 < warp_motion_until;
}
static void show_system_cursor(void) {
    if (!system_cursor_enabled) return;
    system_cursor_enabled=false;
    id arrow=((id (*)(id,SEL))objc_msgSend)((id)objc_getClass("NSCursor"),sel_registerName("arrowCursor"));
    ((void (*)(id,SEL))objc_msgSend)(arrow,sel_registerName("set"));
}
static void apply_game_cursor(void) {
    id cursor=game_system_cursor;
    if (system_cursor_enabled && cursor && !capture_active)
        ((void (*)(id,SEL))objc_msgSend)(cursor,sel_registerName("set"));
}
static int system_cursor_image(lua_State *L) {
    size_t length=0;
    const char *encoded=tolstring(L,1,&length);
    if (encoded && length>0 && length<1048576) {
        id text=((id (*)(id,SEL,const char *))objc_msgSend)((id)objc_getClass("NSString"),sel_registerName("stringWithUTF8String:"),encoded);
        id bytes=((id (*)(id,SEL))objc_msgSend)((id)objc_getClass("NSData"),sel_registerName("alloc"));
        bytes=((id (*)(id,SEL,id,unsigned long))objc_msgSend)(bytes,sel_registerName("initWithBase64EncodedString:options:"),text,0);
        id image=((id (*)(id,SEL))objc_msgSend)((id)objc_getClass("NSImage"),sel_registerName("alloc"));
        image=((id (*)(id,SEL,id))objc_msgSend)(image,sel_registerName("initWithData:"),bytes);
        if (image) {
            CGSize size={32,32};
            ((void (*)(id,SEL,CGSize))objc_msgSend)(image,sel_registerName("setSize:"),size);
            id cursor=((id (*)(id,SEL))objc_msgSend)((id)objc_getClass("NSCursor"),sel_registerName("alloc"));
            CGPoint hotspot={0,0};
            cursor=((id (*)(id,SEL,id,CGPoint))objc_msgSend)(cursor,sel_registerName("initWithImage:hotSpot:"),image,hotspot);
            if (cursor) {
                if (game_system_cursor) ((void (*)(id,SEL))objc_msgSend)(game_system_cursor,sel_registerName("release"));
                game_system_cursor=cursor;
            }
            ((void (*)(id,SEL))objc_msgSend)(image,sel_registerName("release"));
        }
        if (bytes) ((void (*)(id,SEL))objc_msgSend)(bytes,sel_registerName("release"));
    }
    apply_game_cursor();
    pushnumber(L,game_system_cursor?1:0);
    return 1;
}
static bool alt_toggle_mode=true, alt_release_latched, alt_physical_previous;
static int (*warp_mouse_cursor)(CGPoint);

static bool alt_release_state(bool held, bool focused, bool eligible) {
    if (!focused || !eligible) alt_release_latched=false;
    else if (alt_toggle_mode && held && !alt_physical_previous) alt_release_latched=!alt_release_latched;
    alt_physical_previous=held;
    return alt_toggle_mode ? alt_release_latched : held;
}
static int (*associate_mouse_cursor)(bool);
static id capture_focus_observer, capture_window_observer, capture_quit_observer;

static bool native_alt_held(void) {
    Class event_class = objc_getClass("NSEvent");
    if (!event_class) return false;
    unsigned long flags = ((unsigned long (*)(id, SEL))objc_msgSend)
        ((id)event_class, sel_registerName("modifierFlags"));
    return (flags & (1UL << 19)) != 0; /* NSEventModifierFlagOption */
}

static bool native_app_focused(void) {
    Class app_class = objc_getClass("NSApplication");
    if (!app_class) return false;
    id app = ((id (*)(id, SEL))objc_msgSend)((id)app_class, sel_registerName("sharedApplication"));
    bool active = ((bool (*)(id, SEL))objc_msgSend)(app, sel_registerName("isActive"));
    id window = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("keyWindow"));
    return active && window != nil;
}

static bool native_alt_released(void) {
    bool held = native_alt_held(), focused = native_app_focused();
    if (!focused) capture_waits_for_alt = true;
    if (capture_waits_for_alt) {
        bool pressed = focused && held && !alt_physical_previous;
        alt_physical_previous = held;
        alt_release_latched = false;
        if (!pressed) return true;
        capture_waits_for_alt = false;
        return false;
    }
    return alt_release_state(held,focused,
                             capture_requested || capture_active || alt_release_latched);
}

static void center_mouse_cursor(void) {
    if (!warp_mouse_cursor) return;
    id app=((id (*)(id,SEL))objc_msgSend)((id)objc_getClass("NSApplication"),sel_registerName("sharedApplication"));
    id window=((id (*)(id,SEL))objc_msgSend)(app,sel_registerName("keyWindow"));
    if (!window) return;
    id view=((id (*)(id,SEL))objc_msgSend)(window,sel_registerName("contentView"));
    CGRect bounds=((CGRect (*)(id,SEL))objc_msgSend)(view,sel_registerName("bounds"));
    CGPoint point={bounds.origin.x+bounds.size.width/2,bounds.origin.y+bounds.size.height/2};
    point=((CGPoint (*)(id,SEL,CGPoint,id))objc_msgSend)(view,sel_registerName("convertPoint:toView:"),point,nil);
    point=((CGPoint (*)(id,SEL,CGPoint))objc_msgSend)(window,sel_registerName("convertPointToScreen:"),point);
    id screens=((id (*)(id,SEL))objc_msgSend)((id)objc_getClass("NSScreen"),sel_registerName("screens"));
    id primary=((id (*)(id,SEL,unsigned long))objc_msgSend)(screens,sel_registerName("objectAtIndex:"),0);
    CGRect frame=((CGRect (*)(id,SEL))objc_msgSend)(primary,sel_registerName("frame"));
    point.y=frame.origin.y+frame.size.height-point.y;
    warp_motion_until=clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1e9+0.06;
    mouse_pending_x=mouse_pending_y=mouse_frame_x=mouse_frame_y=0;
    mouse_window_x=mouse_screen_width/2; mouse_window_y=mouse_screen_height/2;
    mouse_position_valid=true;
    warp_mouse_cursor(point);
}

static void release_mouse_capture(void) {
    if (!capture_active) return;
    if (associate_mouse_cursor) associate_mouse_cursor(true);
    ((void (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSCursor"), sel_registerName("unhide"));
    capture_active = false;
    mouse_pending_x = mouse_pending_y = mouse_frame_x = mouse_frame_y = 0;
}

static void update_mouse_capture(void) {
    bool focused = native_app_focused();
    bool alt = native_alt_released();
    bool engage = capture_requested && focused && !alt;
    if (!engage) { release_mouse_capture(); return; }
    if (capture_active || !capture_api_ready) return;
    center_mouse_cursor();
    int result = associate_mouse_cursor(false);
    if (result != 0) {
        capture_api_ready = false;
        return;
    }
    ((void (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSCursor"), sel_registerName("hide"));
    capture_active = true;
    mouse_pending_x = mouse_pending_y = mouse_frame_x = mouse_frame_y = 0;
}

static id capture_notification_name(const char *name) {
    return ((id (*)(id, SEL, const char *))objc_msgSend)
        ((id)objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), name);
}

static void install_cursor_capture(void) {
    if (capture_api_ready) return;
    *(void **)(&warp_mouse_cursor) = dlsym(RTLD_DEFAULT, "CGWarpMouseCursorPosition");
    *(void **)(&associate_mouse_cursor) = dlsym(RTLD_DEFAULT, "CGAssociateMouseAndMouseCursorPosition");
    if (!associate_mouse_cursor || !objc_getClass("NSCursor")) return;
    id center = ((id (*)(id, SEL))objc_msgSend)
        ((id)objc_getClass("NSNotificationCenter"), sel_registerName("defaultCenter"));
    SEL observe = sel_registerName("addObserverForName:object:queue:usingBlock:");
    void (^release_on_focus_loss)(id) = ^(id notification) {
        (void)notification;
        show_system_cursor();
        reset_input_keys();
        capture_waits_for_alt = true;
        alt_physical_previous = native_alt_held();
        capture_requested = false;
        alt_release_latched=false;
        release_mouse_capture();
    };
    capture_focus_observer = ((id (*)(id, SEL, id, id, id, void (^)(id)))objc_msgSend)
        (center, observe, capture_notification_name("NSApplicationDidResignActiveNotification"), nil, nil, release_on_focus_loss);
    capture_window_observer = ((id (*)(id, SEL, id, id, id, void (^)(id)))objc_msgSend)
        (center, observe, capture_notification_name("NSWindowDidResignKeyNotification"), nil, nil, release_on_focus_loss);
    capture_quit_observer = ((id (*)(id, SEL, id, id, id, void (^)(id)))objc_msgSend)
        (center, observe, capture_notification_name("NSApplicationWillTerminateNotification"), nil, nil, release_on_focus_loss);
    atexit(release_mouse_capture);
    capture_api_ready = true;
}

static bool scene_mouse_passthrough;
static int mouse_capture(lua_State *L) {
    int valid = 0;
    double requested = tonumberx(L, 1, &valid);
    if (valid && requested==-13) {
        pushnumber(L,(double)ui_left_press);
        pushnumber(L,(double)ui_left_release);
        return 2;
    }
    if (valid && requested==-12) {
        pushnumber(L,alt_toggle_mode?1:0);
        return 1;
    }
    if (valid && requested==-11) {
        // Process-owned latch survives Lua VM and login-session recreation.
        if (!initial_world_capture_used && native_app_focused()) {
            initial_world_capture_used=true;
            capture_waits_for_alt=false;
            alt_release_latched=false;
            alt_physical_previous=native_alt_held();
        }
        pushnumber(L,initial_world_capture_used?1:0);
        return 1;
    }
    if (valid && requested==-10) {
        capture_requested=false;
        capture_waits_for_alt=true;
        alt_release_latched=false;
        alt_physical_previous=native_alt_held();
        reset_input_keys();
        mouse_pending_x=mouse_pending_y=mouse_frame_x=mouse_frame_y=0;
        mouse_pending_wx=mouse_pending_wy=mouse_frame_wx=mouse_frame_wy=0;
        release_mouse_capture();
        show_system_cursor();
    }
    if (valid && requested==-9) { pushnumber(L,warp_motion_suppressed()?1:0); return 1; }
    if (valid && (requested==-7 || requested==-8)) {
        if (requested==-7 && native_app_focused()) { system_cursor_enabled=true;apply_game_cursor(); }
        else show_system_cursor();
    }
    if (valid && (requested == -2 || requested == -3)) {
        bool toggle=requested == -2;
        if (toggle!=alt_toggle_mode) {
            alt_toggle_mode=toggle;
            alt_release_latched=false;
            alt_physical_previous=native_alt_held();
        }
    }
    if (valid && (requested == -5 || requested == -6)) scene_mouse_passthrough = requested == -5;
    if (valid && requested == -4) alt_release_latched=false;
    if (valid && (requested == 0 || requested == 1)) {
        capture_feature_enabled = true;
        capture_requested = requested == 1;
        update_mouse_capture();
    }
    pushnumber(L, native_alt_released() ? 1 : 0);
    pushnumber(L, capture_active ? 1 : 0);
    return 2;
}

/* Per-key held state and per-frame edges; repeated keyDown never releases
 * another key. AppKit and Unity input sampling run on the main thread. */
static bool key_held[512], key_pending_down[512], key_pending_up[512];
static bool key_down_frame[512], key_up_frame[512];
static int key_sample_frame = -1;
static double mouse_sensitivity = 3.0;
static double wheel_sensitivity = 3.0;
static bool (*original_key_held)(int), (*original_key_down)(int), (*original_key_up)(int);
static bool (*original_button_held)(int), (*original_button_down)(int), (*original_button_up)(int);
static int mac_key_to_unity(unsigned short key) {
    static const int map[128] = {
        [0]='a',[1]='s',[2]='d',[3]='f',[4]='h',[5]='g',[6]='z',[7]='x',
        [8]='c',[9]='v',[11]='b',[12]='q',[13]='w',[14]='e',[15]='r',
        [16]='y',[17]='t',[18]='1',[19]='2',[20]='3',[21]='4',[22]='6',
        [23]='5',[24]='=',[25]='9',[26]='7',[27]='-',[28]='8',[29]='0',
        [30]=']',[31]='o',[32]='u',[33]='[',[34]='i',[35]='p',[36]=13,
        [37]='l',[38]='j',[39]=39,[40]='k',[41]=';',[42]=92,[43]=',',
        [44]='/',[45]='n',[46]='m',[47]='.',[48]=9,[49]=32,[50]=96,
        [51]=8,[53]=27,[55]=310,[54]=309,[56]=304,[60]=303,[58]=308,
        [61]=307,[59]=306,[62]=305,[123]=276,[124]=275,[125]=274,[126]=273
    };
    return key < 128 ? map[key] : 0;
}
static void set_input_key(int key, bool down) {
    if (key <= 0 || key >= 512 || key_held[key] == down) return;
    key_held[key] = down;
    if (down) key_pending_down[key] = true; else key_pending_up[key] = true;
}
static void reset_input_keys(void) {
    for (int i=1;i<512;i++) set_input_key(i, false);
}
static void sample_key_edges(void) {
    int frame = unity_frame_count ? unity_frame_count() : -1;
    if (frame == key_sample_frame) return;
    key_sample_frame = frame;
    memcpy(key_down_frame,key_pending_down,sizeof(key_down_frame));
    memcpy(key_up_frame,key_pending_up,sizeof(key_up_frame));
    memset(key_pending_down,0,sizeof(key_pending_down));
    memset(key_pending_up,0,sizeof(key_pending_up));
}
static bool managed_key(int key) {
    for (unsigned short i=0;i<128;i++) if (mac_key_to_unity(i)==key && key) return true;
    return key==323 || key==324 || key==325;
}
static bool input_value(int key, int kind) {
    sample_key_edges();
    if (!native_app_focused()) return false;
    /* Right-button actions remain available in UI and minigames without capture. */
    if ((key==323 || key==325) && (!capture_active || native_alt_released())) return false;
    if (key<=0 || key>=512) return false;
    if (key == 304 && !scene_mouse_passthrough) {
        bool sprint = kind==0 ? key_held[324] : kind==1 ? key_down_frame[324] : key_up_frame[324];
        if (sprint) return true;
    }
    return kind==0 ? key_held[key] : kind==1 ? key_down_frame[key] : key_up_frame[key];
}
static bool native_key_held(int key) { return managed_key(key) ? input_value(key,0) : original_key_held(key); }
static bool native_key_down(int key) { return managed_key(key) ? input_value(key,1) : original_key_down(key); }
static bool native_key_up(int key) { return managed_key(key) ? input_value(key,2) : original_key_up(key); }
static bool native_button_held(int key) {
    if (key == 1) return input_value(324,0);
    if (scene_mouse_passthrough && !capture_active) return native_app_focused() && original_button_held(key);
    return key>=0 && key<=2 ? input_value(323+key,0) : original_button_held(key);
}
static bool native_button_down(int key) {
    if (key == 1) return input_value(324,1);
    if (scene_mouse_passthrough && !capture_active) return native_app_focused() && original_button_down(key);
    return key>=0 && key<=2 ? input_value(323+key,1) : original_button_down(key);
}
static bool native_button_up(int key) {
    if (key == 1) return input_value(324,2);
    if (scene_mouse_passthrough && !capture_active) return native_app_focused() && original_button_up(key);
    return key>=0 && key<=2 ? input_value(323+key,2) : original_button_up(key);
}
static int sensitivity_setting(lua_State *L) {
    int valid=0; double value=tonumberx(L,1,&valid);
    if (valid && isfinite(value) && value>=0.25 && value<=5.0) mouse_sensitivity=value;
    double wheel = tonumberx(L,2,&valid);
    if (valid && isfinite(wheel) && wheel>=0.5 && wheel<=10.0) wheel_sensitivity=wheel;
    pushnumber(L,mouse_sensitivity); return 1;
}

static void mouse_sample_frame(void) {
    int frame = unity_frame_count ? unity_frame_count() : -1;
    if (frame == mouse_frame) return;
    mouse_frame = frame;
    mouse_frame_x = mouse_pending_x; mouse_frame_y = mouse_pending_y;
    mouse_frame_wx = mouse_pending_wx; mouse_frame_wy = mouse_pending_wy;
    mouse_pending_x = mouse_pending_y = mouse_pending_wx = mouse_pending_wy = 0;
}

static int mouse_axis_name(void *string) {
    if (!string) return 0;
    int32_t length = 0;
    memcpy(&length, (const char *)string + 16, 4);
    if (length < 1 || length > 32) return 0;
    static const char *names[] = {"Mouse X", "Mouse Y", "Mouse ScrollWheel"};
    for (int n = 0; n < 3; ++n) {
        if ((int)strlen(names[n]) != length) continue;
        bool same = true;
        for (int i = 0; i < length; ++i) {
            uint16_t c;
            memcpy(&c, (const char *)string + 20 + i * 2, 2);
            unsigned char expected = (unsigned char)names[n][i];
            if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
            if (expected >= 'A' && expected <= 'Z') expected += 'a' - 'A';
            if (c != expected) { same = false; break; }
        }
        if (same) return n + 1;
    }
    return 0;
}

static float mouse_axis_value(int axis) {
    mouse_sample_frame();
    if (axis <= 2 && capture_feature_enabled && !capture_active) return 0;
    float value = (float)(axis == 1 ? mouse_frame_x : axis == 2 ? mouse_frame_y : mouse_frame_wy * wheel_sensitivity);
    return value;
}

static float native_axis_raw(void *name) {
    float original = original_axis_raw(name);
    int axis = mouse_axis_name(name);
    if (axis && axis<=2 && warp_motion_suppressed()) return 0;
    return axis && fabsf(original) < 0.00001f ? mouse_axis_value(axis) : original;
}

static float native_axis(void *name) {
    float original = original_axis(name);
    int axis = mouse_axis_name(name);
    if (axis && axis<=2 && warp_motion_suppressed()) return 0;
    return axis && fabsf(original) < 0.00001f ? mouse_axis_value(axis) : original;
}

static bool native_mouse_present(void) { return true; }
static bool native_cursor_visible(void) {
    return capture_active ? false : original_cursor_visible();
}
static int native_cursor_lock(void) {
    return capture_feature_enabled ? (capture_active ? 1 : 0) : original_cursor_lock();
}
static void native_mouse_position(HSRFloat3 *out) {
    original_mouse_position(out);
    if (capture_active) {
        out->x = (float)(mouse_screen_width / 2); out->y = (float)(mouse_screen_height / 2); out->z = 0;
    } else if (mouse_position_valid) {
        out->x = (float)mouse_window_x; out->y = (float)mouse_window_y; out->z = 0;
    }
}

static void native_scroll_delta(HSRFloat2 *out) {
    original_scroll_delta(out);
    mouse_sample_frame();
    if (fabsf(out->x) < 0.00001f) out->x = (float)(mouse_frame_wx * wheel_sensitivity);
    if (fabsf(out->y) < 0.00001f) out->y = (float)(mouse_frame_wy * wheel_sensitivity);
}

static int mouse_dimensions(lua_State *L) {
    int valid = 0;
    double width = tonumberx(L, 1, &valid);
    if (!valid || width < 100 || width > 20000) return 0;
    double height = tonumberx(L, 2, &valid);
    if (!valid || height < 100 || height > 20000) return 0;
    mouse_screen_width = width; mouse_screen_height = height;
    return 0;
}

static bool install_mouse_bridge(void) {
    if (mouse_bridge_active) return true;
    if (!unity_slide || !pthread_main_np()) return false;
    uintptr_t table = unity_slide + 0x1656d2b0;
    Class events = objc_getClass("NSEvent");
    if (!events) return false;
    const uint64_t mask = (1ULL << 1) | (1ULL << 2) | (1ULL << 3) | (1ULL << 4)
                        | (1ULL << 5) | (1ULL << 6) | (1ULL << 7) | (1ULL << 22)
                        | (1ULL << 10) | (1ULL << 11) | (1ULL << 12) | (1ULL << 25) | (1ULL << 26) | (1ULL << 27);
    id (^handler)(id) = ^id(id event) {
        unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(event, sel_registerName("type"));
        id window = ((id (*)(id, SEL))objc_msgSend)(event, sel_registerName("window"));
        if (window && native_app_focused()) {
            if (type==1) ui_left_press++;
            if (type==2) ui_left_release++;
        }
        if (type == 12 || type == 10 || type == 11) {
            if (native_alt_released() || !native_app_focused()) release_mouse_capture();
            if (type == 10) {
                unsigned short key = ((unsigned short (*)(id, SEL))objc_msgSend)(event, sel_registerName("keyCode"));
                if (key == 53) release_mouse_capture(); /* Escape */
                if (key == 48 && !key_held[9]) { /* Tab wheel opening edge */
                    release_mouse_capture();
                    center_mouse_cursor();
                    mouse_window_x = mouse_screen_width / 2;
                    mouse_window_y = mouse_screen_height / 2;
                    mouse_position_valid = true;
                    mouse_pending_x = mouse_pending_y = 0;
                    mouse_frame_x = mouse_frame_y = 0;
                }
            }
        }
        if (type == 10 || type == 11) {
            unsigned short mac = ((unsigned short (*)(id, SEL))objc_msgSend)(event, sel_registerName("keyCode"));
            set_input_key(mac_key_to_unity(mac), type == 10);
        } else if (type == 12) {
            unsigned long flags = ((unsigned long (*)(id, SEL))objc_msgSend)(event, sel_registerName("modifierFlags"));
            set_input_key(304,(flags & (1UL<<17))!=0);
            set_input_key(308,(flags & (1UL<<19))!=0);
            set_input_key(306,(flags & (1UL<<18))!=0);
        }
        if (type>=1 && type<=4) {
            int code = type<=2 ? 323 : 324;
            bool down = type==1 || type==3;
            bool eligible = code == 324 ? native_app_focused() : capture_active && !native_alt_released();
            set_input_key(code, down && eligible);
        }
        if (native_alt_released()) set_input_key(323,false);
        if (window && ((type >= 1 && type <= 7) || type == 22 || (type >= 25 && type <= 27))) {
            ((void (*)(id, SEL, bool))objc_msgSend)(window, sel_registerName("setAcceptsMouseMovedEvents:"), true);
            id view = ((id (*)(id, SEL))objc_msgSend)(window, sel_registerName("contentView"));
            CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel_registerName("bounds"));
            CGPoint point = ((CGPoint (*)(id, SEL))objc_msgSend)(event, sel_registerName("locationInWindow"));
            point = ((CGPoint (*)(id, SEL, CGPoint, id))objc_msgSend)
                (view, sel_registerName("convertPoint:fromView:"), point, nil);
            if (bounds.size.width > 0 && bounds.size.height > 0) {
                mouse_window_x = (point.x - bounds.origin.x) * mouse_screen_width / bounds.size.width;
                mouse_window_y = (point.y - bounds.origin.y) * mouse_screen_height / bounds.size.height;
                mouse_position_valid = true;
                if (point.x>=bounds.origin.x && point.y>=bounds.origin.y &&
                    point.x<bounds.origin.x+bounds.size.width && point.y<bounds.origin.y+bounds.size.height)
                    apply_game_cursor();
                else if (system_cursor_enabled) {
                    id arrow=((id (*)(id,SEL))objc_msgSend)((id)objc_getClass("NSCursor"),sel_registerName("arrowCursor"));
                    ((void (*)(id,SEL))objc_msgSend)(arrow,sel_registerName("set"));
                }
            }
        }
        if (type == 22) {
            bool precise = ((bool (*)(id, SEL))objc_msgSend)(event, sel_registerName("hasPreciseScrollingDeltas"));
            double x = ((double (*)(id, SEL))objc_msgSend)(event, sel_registerName("scrollingDeltaX"));
            double y = ((double (*)(id, SEL))objc_msgSend)(event, sel_registerName("scrollingDeltaY"));
            if (!warp_motion_suppressed() && isfinite(x) && isfinite(y)) {
                double scale = precise ? 0.01 : 0.1;
                mouse_pending_wx += x * scale; mouse_pending_wy += y * scale;
            }
        } else if (type == 5 || type == 6 || type == 7 || type == 27) {
            double x = ((double (*)(id, SEL))objc_msgSend)(event, sel_registerName("deltaX"));
            double y = ((double (*)(id, SEL))objc_msgSend)(event, sel_registerName("deltaY"));
            if (!warp_motion_suppressed() && isfinite(x) && isfinite(y)) {
                mouse_pending_x += x * 0.1 * mouse_sensitivity; mouse_pending_y -= y * 0.1 * mouse_sensitivity;
            }
        }
        return event;
    };
    mouse_monitor = ((id (*)(id, SEL, uint64_t, id (^)(id)))objc_msgSend)
        ((id)events, sel_registerName("addLocalMonitorForEventsMatchingMask:handler:"), mask, handler);
    if (!mouse_monitor) return false;
    ((id (*)(id, SEL))objc_msgSend)(mouse_monitor, sel_registerName("retain"));
    unity_frame_count = (void *)*(uintptr_t *)(table + 0x5740);
    original_axis_raw = (void *)*(uintptr_t *)(table + 0xd90);
    original_axis = (void *)*(uintptr_t *)(table + 0xd88);
    original_mouse_position = (void *)*(uintptr_t *)(table + 0xec8);
    original_scroll_delta = (void *)*(uintptr_t *)(table + 0xed0);
    __atomic_store_n((uintptr_t *)(table + 0xd90), (uintptr_t)native_axis_raw, __ATOMIC_RELEASE);
    __atomic_store_n((uintptr_t *)(table + 0xd88), (uintptr_t)native_axis, __ATOMIC_RELEASE);
    __atomic_store_n((uintptr_t *)(table + 0xec8), (uintptr_t)native_mouse_position, __ATOMIC_RELEASE);
    __atomic_store_n((uintptr_t *)(table + 0xed0), (uintptr_t)native_scroll_delta, __ATOMIC_RELEASE);
    __atomic_store_n((uintptr_t *)(table + 0xe30), (uintptr_t)native_mouse_present, __ATOMIC_RELEASE);
    original_cursor_visible = (void *)*(uintptr_t *)(table + 0x1e68);
    original_cursor_lock = (void *)*(uintptr_t *)(table + 0x1e78);
    __atomic_store_n((uintptr_t *)(table + 0x1e68), (uintptr_t)native_cursor_visible, __ATOMIC_RELEASE);
    __atomic_store_n((uintptr_t *)(table + 0x1e78), (uintptr_t)native_cursor_lock, __ATOMIC_RELEASE);
    original_key_held = (void *)*(uintptr_t *)(table+0xd50);
    original_key_up = (void *)*(uintptr_t *)(table+0xd60);
    original_key_down = (void *)*(uintptr_t *)(table+0xd78);
    original_button_held = (void *)*(uintptr_t *)(table+0xdb0);
    original_button_down = (void *)*(uintptr_t *)(table+0xdb8);
    original_button_up = (void *)*(uintptr_t *)(table+0xdc0);
    __atomic_store_n((uintptr_t *)(table+0xd50),(uintptr_t)native_key_held,__ATOMIC_RELEASE);
    __atomic_store_n((uintptr_t *)(table+0xd60),(uintptr_t)native_key_up,__ATOMIC_RELEASE);
    __atomic_store_n((uintptr_t *)(table+0xd78),(uintptr_t)native_key_down,__ATOMIC_RELEASE);
    __atomic_store_n((uintptr_t *)(table+0xdb0),(uintptr_t)native_button_held,__ATOMIC_RELEASE);
    __atomic_store_n((uintptr_t *)(table+0xdb8),(uintptr_t)native_button_down,__ATOMIC_RELEASE);
    __atomic_store_n((uintptr_t *)(table+0xdc0),(uintptr_t)native_button_up,__ATOMIC_RELEASE);
    install_cursor_capture();
    mouse_bridge_active = true;
    return true;
}

static bool resolve_api(void) {
    if (ready) return true;
    if (!unity_handle) {
        for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
            const char *name = _dyld_get_image_name(i);
            if (name && strstr(name, "/UnityFramework.framework/UnityFramework")) {
                unity_handle = dlopen(name, RTLD_LAZY | RTLD_NOLOAD);
                break;
            }
        }
    }
    if (!unity_handle) return false;
#define RESOLVE(var, name) *(void **)(&var) = dlsym(unity_handle, name)
    RESOLVE(gettop, "lua_gettop");
    RESOLVE(settop, "lua_settop");
    RESOLVE(tolstring, "lua_tolstring");
    RESOLVE(compile_source, "luau_compile");
    RESOLVE(load_chunk, "luau_load");
    RESOLVE(tonumberx, "lua_tonumberx");
    RESOLVE(pushnumber, "lua_pushnumber");
    RESOLVE(pushstring, "lua_pushstring");
    RESOLVE(pushclosure, "lua_pushcclosurek");
    RESOLVE(setglobal, "lua_setglobal");
    RESOLVE(getfield, "lua_getfield");
    RESOLVE(luatype, "lua_type");
    RESOLVE(luatypename, "lua_typename");
#undef RESOLVE
    ready = gettop && settop && tolstring && compile_source && load_chunk
         && tonumberx && pushnumber && pushstring && pushclosure && setglobal && getfield && luatype && luatypename;
    return ready;
}

static void initialize_playtools(lua_State *L) {
    if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9 < initialization_not_before || !resolve_api()) return;
    if (script_initialized) {
        int top = gettop(L);
        getfield(L, -10002, "__HSRNativeInputFrame");
        bool present = strcmp(luatypename(L, luatype(L, -1)), "function") == 0;
        settop(L, top);
        if (present) { install_mouse_bridge(); return; }
        script_initialized = false;
    }
    if (last_init_failure == time(NULL)) return;
    // Immutable embedded bytecode is shared by subsequent Lua environments.
    if (!startup_bytecode) {
        startup_bytecode = compile_source((const char *)embedded_lua, sizeof(embedded_lua)-1, NULL, &startup_bytecode_size);
        if (!startup_bytecode) { last_init_failure = time(NULL); return; }
    }
    int before = gettop(L);
    pushclosure(L, display_version, "HSRVersion", 0, NULL);
    setglobal(L, "__HSRVersion");
    pushclosure(L, scale_baseline, "HSRScaleBaseline", 0, NULL);
    setglobal(L, "__HSRScaleBaseline");
    pushclosure(L, sensitivity_setting, "HSRSensitivity", 0, NULL);
    setglobal(L, "__HSRSensitivity");
    pushclosure(L, mouse_dimensions, "HSRMouseDimensions", 0, NULL);
    setglobal(L, "__HSRMouseDimensions");
    pushclosure(L, mouse_capture, "HSRMouseCapture", 0, NULL);
    setglobal(L, "__HSRMouseCapture");
    pushclosure(L, system_cursor_image, "HSRCursorImage", 0, NULL);
    setglobal(L, "__HSRCursorImage");
    int result = load_chunk(L, "@HSRPlayTools", startup_bytecode, startup_bytecode_size, 0);
    if (result == 0) result = original_pcall(L, 0, 1, 0);
    if (result == 0) {
        getfield(L, -10002, "__HSRNativeInputFrame");
        script_initialized = strcmp(luatypename(L, luatype(L, -1)), "function") == 0;
        if (!script_initialized) last_init_failure = time(NULL);
    } else last_init_failure = time(NULL);
    settop(L, before);
    if (script_initialized) install_mouse_bridge();
}

static void process_native_input(lua_State *L) {
    if (!ready || !mouse_bridge_active) return;
    mouse_sample_frame();
    update_mouse_capture();
    if (mouse_frame == last_ui_input_frame) return;
    int before = gettop(L);
    getfield(L, -10002, "__HSRNativeInputFrame"); /* LUA_GLOBALSINDEX */
    if (strcmp(luatypename(L, luatype(L, -1)), "function") == 0) {
        last_ui_input_frame = mouse_frame;
        original_pcall(L, 0, 0, 0);
    }
    settop(L, before);
}

static int playtools_pcall(lua_State *L, int nargs, int nresults, int errfunc) {
    PCall fn = original_pcall;
    if (!fn) return -1;
    bool nested = entering;
    entering = true;
    int result = fn(L, nargs, nresults, errfunc);
    if (!nested && result == 0 && pthread_main_np()) { initialize_playtools(L); process_native_input(L); }
    entering = nested;
    return result;
}

/* dyld supplies the image before its game initialization runs. */
static void image_added(const struct mach_header *header, intptr_t slide) {
    // Select the target module by path, without UUID or instruction checks.
    bool target=false;
    for (uint32_t i=0;i<_dyld_image_count();i++) {
        if (_dyld_get_image_header(i)!=header) continue;
        const char *name=_dyld_get_image_name(i);
        target=name && strstr(name,"/UnityFramework.framework/UnityFramework");
        break;
    }
    if (!target) return;
    uintptr_t base = (uintptr_t)slide;
    if (original_pcall) return;
    unity_slide = base;
    void *trampoline=runtime_trampoline((void *)(base+HSR_ENTRY));
    if (!trampoline) return;
    original_pcall=(PCall)trampoline;
    const uint32_t pc_code[]={0x52800020,0xd65f03c0};
    if (!runtime_write((void *)(base+HSR_PC_MODE),pc_code,sizeof(pc_code))) {
        original_pcall=NULL; return;
    }
    unsigned char branch[16];
    runtime_jump(branch,(uintptr_t)playtools_pcall);
    if (!runtime_write((void *)(base+HSR_ENTRY),branch,sizeof(branch))) {
        original_pcall=NULL; return;
    }
}

__attribute__((constructor)) static void initialize(void) {
    initialization_not_before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9 + 3.0;
    _dyld_register_func_for_add_image(image_added);
}
