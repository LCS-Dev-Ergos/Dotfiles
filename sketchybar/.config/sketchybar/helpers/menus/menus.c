#include <Carbon/Carbon.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Constants
#define MAX_BUFFER_SIZE          512
#define MAX_NAME_BUFFER          256

static const int MENU_BAR_LAYER           = 0x19;
static const int MAIN_DISPLAY             = 0;
static const int CLICK_DELAY_MICROSECONDS = 150000; // 150ms

/**
 * Initializes accessibility API access
 *
 * @return true if initialization succeeds, false otherwise
 */
[[nodiscard]] static bool ax_init() {
  const void* keys[]   = {kAXTrustedCheckOptionPrompt};
  const void* values[] = {kCFBooleanTrue};

  CFDictionaryRef options = CFDictionaryCreate(
      kCFAllocatorDefault, keys, values, sizeof(keys) / sizeof(*keys), &kCFCopyStringDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);

  if (!options) {
    fprintf(stderr, "Error creating options dictionary\n");
    return false;
  }

  bool trusted = AXIsProcessTrustedWithOptions(options);
  CFRelease(options);

  if (!trusted) {
    fprintf(stderr, "Accessibility permissions not granted\n");
    return false;
  }

  return true;
}

/**
 * Performs a click on a UI element
 *
 * @param element Element to click on
 */
static void ax_perform_click(AXUIElementRef element) {
  if (!element)
    return;

  // First cancel any ongoing action
  AXUIElementPerformAction(element, kAXCancelAction);
  usleep(CLICK_DELAY_MICROSECONDS);

  // Then perform the press action
  AXUIElementPerformAction(element, kAXPressAction);
}

/**
 * Gets the title of a UI element
 *
 * @param element Element to get the title from
 * @return The element's title, or NULL on error
 */
[[nodiscard]] static CFStringRef ax_get_title(AXUIElementRef element) {
  if (!element)
    return NULL;

  CFTypeRef title = NULL;
  AXError   error = AXUIElementCopyAttributeValue(element, kAXTitleAttribute, &title);

  if (error != kAXErrorSuccess)
    return NULL;
  return (CFStringRef)title;
}

/**
 * Selects a menu option by ID
 *
 * @param app Application containing the menu
 * @param id ID of the option to select
 */
static void ax_select_menu_option(AXUIElementRef app, int id) {
  if (!app || id < 0)
    return;

  AXUIElementRef menubars_ref = NULL;
  CFArrayRef     children_ref = NULL;

  AXError error = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute, (CFTypeRef*)&menubars_ref);

  if (error == kAXErrorSuccess && menubars_ref) {
    error = AXUIElementCopyAttributeValue(menubars_ref, kAXVisibleChildrenAttribute, (CFTypeRef*)&children_ref);

    if (error == kAXErrorSuccess && children_ref) {
      CFIndex count = CFArrayGetCount(children_ref);
      if (id < count) {
        AXUIElementRef item = (AXUIElementRef)CFArrayGetValueAtIndex(children_ref, id);
        ax_perform_click(item);
      }
      CFRelease(children_ref);
    }
    CFRelease(menubars_ref);
  }
}

/**
 * Prints available menu options
 *
 * @param app Application containing the menu
 */
static void ax_print_menu_options(AXUIElementRef app) {
  if (!app)
    return;

  AXUIElementRef menubars_ref = NULL;
  CFArrayRef     children_ref = NULL;

  AXError error = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute, (CFTypeRef*)&menubars_ref);

  if (error == kAXErrorSuccess && menubars_ref) {
    error = AXUIElementCopyAttributeValue(menubars_ref, kAXVisibleChildrenAttribute, (CFTypeRef*)&children_ref);

    if (error == kAXErrorSuccess && children_ref) {
      CFIndex count = CFArrayGetCount(children_ref);

      for (CFIndex i = 1; i < count; i++) {
        AXUIElementRef item  = (AXUIElementRef)CFArrayGetValueAtIndex(children_ref, i);
        CFStringRef    title = ax_get_title(item);

        if (title) {
          CFIndex title_length = CFStringGetLength(title);
          if (title_length > 0) {
            // Safe buffer allocation for the string
            CFIndex buffer_size = CFStringGetMaximumSizeForEncoding(title_length, kCFStringEncodingUTF8) + 1;
            char*   buffer      = (char*)malloc(buffer_size);

            if (buffer) {
              if (CFStringGetCString(title, buffer, buffer_size, kCFStringEncodingUTF8)) {
                printf("%s\n", buffer);
              }
              free(buffer);
            }
          }
          CFRelease(title);
        }
      }
      CFRelease(children_ref);
    }
    CFRelease(menubars_ref);
  }
}

/**
 * Gets an extra menu item (icons in the system menubar)
 *
 * @param alias Application,window alias
 * @return The corresponding UI element, or NULL on error
 */
[[nodiscard]] static AXUIElementRef ax_get_extra_menu_item(const char* alias) {
  if (!alias)
    return NULL;

  pid_t      pid         = 0;
  CGRect     bounds      = CGRectNull;
  CFArrayRef window_list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);

  if (!window_list) {
    fprintf(stderr, "Unable to get window list\n");
    return NULL;
  }

  char owner_buffer[MAX_NAME_BUFFER] = {0};
  char name_buffer[MAX_NAME_BUFFER]  = {0};
  char buffer[MAX_BUFFER_SIZE]       = {0};
  int  window_count                  = CFArrayGetCount(window_list);

  for (int i = 0; i < window_count; ++i) {
    CFDictionaryRef dictionary = CFArrayGetValueAtIndex(window_list, i);
    if (!dictionary)
      continue;

    CFStringRef     owner_ref     = CFDictionaryGetValue(dictionary, kCGWindowOwnerName);
    CFNumberRef     owner_pid_ref = CFDictionaryGetValue(dictionary, kCGWindowOwnerPID);
    CFStringRef     name_ref      = CFDictionaryGetValue(dictionary, kCGWindowName);
    CFNumberRef     layer_ref     = CFDictionaryGetValue(dictionary, kCGWindowLayer);
    CFDictionaryRef bounds_ref    = CFDictionaryGetValue(dictionary, kCGWindowBounds);

    if (!name_ref || !owner_ref || !owner_pid_ref || !layer_ref || !bounds_ref)
      continue;

    long long int layer = 0;
    CFNumberGetValue(layer_ref, CFNumberGetType(layer_ref), &layer);

    uint64_t owner_pid = 0;
    CFNumberGetValue(owner_pid_ref, CFNumberGetType(owner_pid_ref), &owner_pid);

    if (layer != MENU_BAR_LAYER)
      continue;

    bounds = CGRectNull;
    if (!CGRectMakeWithDictionaryRepresentation(bounds_ref, &bounds))
      continue;

    if (!CFStringGetCString(owner_ref, owner_buffer, sizeof(owner_buffer), kCFStringEncodingUTF8)
        || !CFStringGetCString(name_ref, name_buffer, sizeof(name_buffer), kCFStringEncodingUTF8))
      continue;

    int snprintf_result = snprintf(buffer, sizeof(buffer), "%s,%s", owner_buffer, name_buffer);
    if (snprintf_result < 0 || snprintf_result >= (int)sizeof(buffer))
      continue;

    if (strcmp(buffer, alias) == 0) {
      pid = owner_pid;
      break;
    }
  }

  CFRelease(window_list);

  if (!pid) {
    return NULL;
  }

  AXUIElementRef app = AXUIElementCreateApplication(pid);
  if (!app) {
    return NULL;
  }

  AXUIElementRef result       = NULL;
  CFTypeRef      extras       = NULL;
  CFArrayRef     children_ref = NULL;

  AXError error = AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute, &extras);
  if (error == kAXErrorSuccess && extras) {
    error = AXUIElementCopyAttributeValue(extras, kAXVisibleChildrenAttribute, (CFTypeRef*)&children_ref);

    if (error == kAXErrorSuccess && children_ref) {
      CFIndex count = CFArrayGetCount(children_ref);
      for (CFIndex i = 0; i < count; i++) {
        AXUIElementRef item         = (AXUIElementRef)CFArrayGetValueAtIndex(children_ref, i);
        CFTypeRef      position_ref = NULL;
        CFTypeRef      size_ref     = NULL;

        AXUIElementCopyAttributeValue(item, kAXPositionAttribute, &position_ref);
        AXUIElementCopyAttributeValue(item, kAXSizeAttribute, &size_ref);

        if (!position_ref || !size_ref) {
          if (position_ref)
            CFRelease(position_ref);
          if (size_ref)
            CFRelease(size_ref);
          continue;
        }

        CGPoint position = CGPointZero;
        AXValueGetValue(position_ref, kAXValueCGPointType, &position);

        CGSize size = CGSizeZero;
        AXValueGetValue(size_ref, kAXValueCGSizeType, &size);

        CFRelease(position_ref);
        CFRelease(size_ref);

        // 10 point tolerance for positioning
        static const CGFloat POSITION_TOLERANCE = 10.0;
        if (fabs(position.x - bounds.origin.x) <= POSITION_TOLERANCE) {
          result = (AXUIElementRef)CFRetain(item);
          break;
        }
      }
      CFRelease(children_ref);
    }
    CFRelease(extras);
  }

  CFRelease(app);
  return result;
}

// SkyLight function declarations
extern int  SLSMainConnectionID();
extern void SLSSetMenuBarVisibilityOverrideOnDisplay(int cid, int did, bool enabled);
extern void SLSSetMenuBarInsetAndAlpha(int cid, double u1, double u2, float alpha);

/**
 * Selects an item from the extra menu
 *
 * @param alias Application,window alias
 */
static void ax_select_menu_extra(const char* alias) {
  if (!alias)
    return;

  AXUIElementRef item = ax_get_extra_menu_item(alias);
  if (!item) {
    fprintf(stderr, "Unable to find menu item: %s\n", alias);
    return;
  }

  int connection_id = SLSMainConnectionID();

  // Temporarily hide the menubar
  SLSSetMenuBarInsetAndAlpha(connection_id, 0, 1, 0.0);
  SLSSetMenuBarVisibilityOverrideOnDisplay(connection_id, MAIN_DISPLAY, true);
  SLSSetMenuBarInsetAndAlpha(connection_id, 0, 1, 0.0);

  // Perform the click on the element
  ax_perform_click(item);

  // Restore the menubar
  SLSSetMenuBarVisibilityOverrideOnDisplay(connection_id, MAIN_DISPLAY, false);
  SLSSetMenuBarInsetAndAlpha(connection_id, 0, 1, 1.0);

  CFRelease(item);
}

// Process Serial Number function declarations
extern void _SLPSGetFrontProcess(ProcessSerialNumber* psn);
extern void SLSGetConnectionIDForPSN(int cid, ProcessSerialNumber* psn, int* cid_out);
extern void SLSConnectionGetPID(int cid, pid_t* pid_out);

/**
 * Gets the frontmost application
 *
 * @return The UI element of the frontmost application, or NULL on error
 */
[[nodiscard]] static AXUIElementRef ax_get_front_app() {
  ProcessSerialNumber psn = {0};
  _SLPSGetFrontProcess(&psn);

  int connection_id = SLSMainConnectionID();
  int target_cid    = 0;
  SLSGetConnectionIDForPSN(connection_id, &psn, &target_cid);

  pid_t pid = 0;
  SLSConnectionGetPID(target_cid, &pid);

  if (pid == 0) {
    fprintf(stderr, "Unable to get PID of frontmost application\n");
    return NULL;
  }

  return AXUIElementCreateApplication(pid);
}

/**
 * Shows program usage
 */
static void show_usage(const char* program_name) {
  if (!program_name)
    program_name = "menus";
  printf("Usage: %s [-l | -s id/alias ]\n", program_name);
  printf("  -l: List menu options in the frontmost app\n");
  printf("  -s id: Select menu option with specified ID\n");
  printf(
      "  -s alias: Select extra menu option with specified alias (format: "
      "'app,name')\n");
}

int main(int argc, char** argv) {
  if (argc == 1) {
    show_usage(argv[0]);
    exit(0);
  }

  if (!ax_init()) {
    fprintf(stderr, "Error initializing accessibility APIs\n");
    return 1;
  }

  if (strcmp(argv[1], "-l") == 0) {
    AXUIElementRef app = ax_get_front_app();
    if (!app) {
      fprintf(stderr, "Unable to get frontmost application\n");
      return 1;
    }
    ax_print_menu_options(app);
    CFRelease(app);
  } else if (argc == 3 && strcmp(argv[1], "-s") == 0) {
    int id = 0;
    if (sscanf(argv[2], "%d", &id) == 1) {
      // Select by numeric ID
      AXUIElementRef app = ax_get_front_app();
      if (!app) {
        fprintf(stderr, "Unable to get frontmost application\n");
        return 1;
      }
      ax_select_menu_option(app, id);
      CFRelease(app);
    } else {
      // Select by alias
      ax_select_menu_extra(argv[2]);
    }
  } else {
    show_usage(argv[0]);
    return 1;
  }

  return 0;
}
