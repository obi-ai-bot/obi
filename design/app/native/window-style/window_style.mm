// Gives an Electron window the window type Safari uses on macOS: one with an
// empty, invisible toolbar. macOS then draws that type's own corners (the
// larger macOS 26 radius) and places the traffic lights itself. Nothing is
// drawn by hand. Electron has no option for this yet (electron/electron#47514).
//
// Full screen: macOS snapshots the window when leaving full screen and rounds
// that snapshot with the plain window's smaller corners, which shows as dark
// corners on a toolbar window. So the toolbar comes off just before entering
// full screen and goes back on once it has left.

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <node_api.h>

static void addToolbar(NSWindow* window) {
  NSToolbar* toolbar = [[NSToolbar alloc] initWithIdentifier:@"oby.window"];
  toolbar.displayMode = NSToolbarDisplayModeIconOnly;
  toolbar.allowsUserCustomization = NO;
  toolbar.autosavesConfiguration = NO;
  if (@available(macOS 15.0, *)) toolbar.allowsDisplayModeCustomization = NO;
  window.toolbar = toolbar;
  window.toolbarStyle = NSWindowToolbarStyleUnified;
}

// once per window: take the toolbar off around full screen, stop on close
static char kWatching;
static void watchFullScreen(NSWindow* window) {
  if (objc_getAssociatedObject(window, &kWatching)) return;
  objc_setAssociatedObject(window, &kWatching, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  __weak NSWindow* weak = window;
  id enter = [center addObserverForName:NSWindowWillEnterFullScreenNotification object:window queue:nil
                             usingBlock:^(NSNotification*) { weak.toolbar = nil; }];
  id exit = [center addObserverForName:NSWindowDidExitFullScreenNotification object:window queue:nil
                            usingBlock:^(NSNotification*) { if (weak) addToolbar(weak); }];
  __block id close = [center addObserverForName:NSWindowWillCloseNotification object:window queue:nil
                                     usingBlock:^(NSNotification*) {
    NSNotificationCenter* c = NSNotificationCenter.defaultCenter;
    [c removeObserver:enter];
    [c removeObserver:exit];
    [c removeObserver:close];
    close = nil;  // lets this block and its observer go
  }];
}

static napi_value number(napi_env env, double v) {
  napi_value out;
  napi_create_double(env, v, &out);
  return out;
}

// useToolbarWindow(win.getNativeWindowHandle())
//   → { lightsLeft, lightsTop, lightsCenterY, lightsRight }
// where macOS placed the traffic lights for this window type, in CSS px from
// the window's top-left. Electron moves them back to its own spot afterwards,
// so the caller hands lightsLeft/lightsTop to win.setWindowButtonPosition().
static napi_value UseToolbarWindow(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  void* data = NULL;
  size_t length = 0;
  if (argc < 1 || napi_get_buffer_info(env, argv[0], &data, &length) != napi_ok || length < sizeof(void*)) {
    napi_throw_type_error(env, NULL, "useToolbarWindow: pass win.getNativeWindowHandle()");
    return NULL;
  }
  NSView* view = (__bridge NSView*)(*(void**)data);
  NSWindow* window = view.window;
  if (!window) return NULL;

  addToolbar(window);
  watchFullScreen(window);
  window.titlebarAppearsTransparent = YES;
  window.titleVisibility = NSWindowTitleHidden;
  window.styleMask |= NSWindowStyleMaskFullSizeContentView;

  // let macOS lay out the title bar, then read where the traffic lights are
  NSView* frameView = window.contentView.superview;
  [frameView layoutSubtreeIfNeeded];
  NSButton* close = [window standardWindowButton:NSWindowCloseButton];
  NSButton* zoom = [window standardWindowButton:NSWindowZoomButton];
  if (!close || !zoom) return NULL;
  NSRect c = [close convertRect:close.bounds toView:nil];
  NSRect z = [zoom convertRect:zoom.bounds toView:nil];
  CGFloat height = window.contentView.bounds.size.height;

  napi_value out;
  napi_create_object(env, &out);
  napi_set_named_property(env, out, "lightsLeft", number(env, NSMinX(c)));
  napi_set_named_property(env, out, "lightsTop", number(env, height - NSMaxY(c)));
  napi_set_named_property(env, out, "lightsCenterY", number(env, height - NSMidY(c)));
  napi_set_named_property(env, out, "lightsRight", number(env, NSMaxX(z)));
  return out;
}

NAPI_MODULE_INIT() {
  napi_value fn;
  napi_create_function(env, "useToolbarWindow", NAPI_AUTO_LENGTH, UseToolbarWindow, NULL, &fn);
  napi_set_named_property(env, exports, "useToolbarWindow", fn);
  return exports;
}
