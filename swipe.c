#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WORKSPACE_NAME_SIZE 16
#define MAX_WORKSPACES 32
#define SWIPE_THRESHOLD 0.15f
#define SWIPE_VELOCITY_THRESHOLD 0.5f
#define SWIPE_COOLDOWN 0.3
#define NATURAL_SWIPE 1
#define SKIP_EMPTY 1
#define WRAP_AROUND 1

#if NATURAL_SWIPE
#define SWIPE_LEFT "next"
#define SWIPE_RIGHT "prev"
#else
#define SWIPE_LEFT "prev"
#define SWIPE_RIGHT "next"
#endif

static pthread_mutex_t gestureMutex = PTHREAD_MUTEX_INITIALIZER;

static char aerospace_path[256] = {0};

static const char *try_fallback_paths(void) {
  const char *fallback_paths[] = {"/opt/homebrew/bin/aerospace",
                                  "/usr/local/bin/aerospace",
                                  "/usr/bin/aerospace"};
  for (size_t i = 0; i < sizeof(fallback_paths) / sizeof(fallback_paths[0]);
       i++) {
    if (access(fallback_paths[i], X_OK) == 0) {
      strncpy(aerospace_path, fallback_paths[i], sizeof(aerospace_path) - 1);
      aerospace_path[sizeof(aerospace_path) - 1] = '\0';
      return aerospace_path;
    }
  }
  return NULL;
}

static const char *get_aerospace_path(void) {
  if (aerospace_path[0] != '\0') {
    return aerospace_path;
  }

  FILE *fp = popen("command -v aerospace", "r");
  if (fp) {
    if (fgets(aerospace_path, sizeof(aerospace_path), fp)) {
      aerospace_path[strcspn(aerospace_path, "\n")] = '\0';
    }
    pclose(fp);
  }

  if (aerospace_path[0] == '\0') {
    if (!try_fallback_paths()) {
      fprintf(stderr, "Error: Could not find the 'aerospace' binary in PATH or "
                      "fallback locations.\n");
      return NULL;
    }
  }
  return aerospace_path;
}

typedef void *MTDeviceRef;

typedef struct {
  float x, y;
} mtPoint;

typedef struct {
  mtPoint pos, vel;
} mtReadout;

typedef struct {
  int frame;
  double timestamp;
  int identifier, state, foo3, foo4;
  mtReadout normalized;
  float size;
  int zero1;
  float angle, majorAxis, minorAxis;
  mtReadout mm;
  int zero2[2];
  float unk2;
} MtTouch;

typedef void (*MTContactCallbackFunction)(int device, MtTouch *data,
                                          int nFingers, double timestamp,
                                          int frame);

static void switch_workspace(const char *ws) {
  const char *aero = get_aerospace_path();
  if (!aero || aero[0] == '\0') {
    return;
  }

  char list_workspaces_cmd[512];
  int list_len = snprintf(list_workspaces_cmd, sizeof(list_workspaces_cmd),
                 "%s list-workspaces --monitor focused --empty no | ",
                 aero);
  char* switch_workspace_cmd = list_workspaces_cmd + list_len;

  snprintf(switch_workspace_cmd, sizeof(list_workspaces_cmd) - list_len * sizeof(char),
           "%s workspace %s%s", aero, WRAP_AROUND ? "--wrap-around " : "", ws);

  char* cmd = WRAP_AROUND ? list_workspaces_cmd : switch_workspace_cmd;
  printf("Executing: %s\n", cmd);
  int ret = system(cmd);
  if (ret != 0) {
    fprintf(stderr, "Error: Command failed: %s\n", cmd);
  }
}

static void gestureCallback(int _device, MtTouch *contacts, int numContacts,
                            double timestamp, int _frame) {
  pthread_mutex_lock(&gestureMutex);

  static bool swiping = false;
  static float startAvgX = 0.0f;
  static double lastSwipeTime = 0.0;
  static int consecutiveRightFrames = 0;
  static int consecutiveLeftFrames = 0;

  int activeFingers = 0;
  for (int i = 0; i < numContacts; i++) {
    if (contacts[i].size > 0.05f) { // This threshold may need tuning
      activeFingers++;
    }
  }

  // Only proceed if exactly three active fingers are detected and if we're
  // not in cooldown.
  if (activeFingers != 3 || timestamp - lastSwipeTime < SWIPE_COOLDOWN) {
    swiping = false;
    consecutiveRightFrames = 0;
    consecutiveLeftFrames = 0;
    pthread_mutex_unlock(&gestureMutex);
    return;
  }

  float avgX = 0.0f;
  float avgVelX = 0.0f;
  for (int i = 0; i < numContacts; i++) {
    avgX += contacts[i].normalized.pos.x;
    avgVelX += contacts[i].normalized.vel.x;
  }
  avgX /= numContacts;
  avgVelX /= numContacts;

  if (!swiping) {
    swiping = true;
    startAvgX = avgX;
    consecutiveRightFrames = 0;
    consecutiveLeftFrames = 0;
  } else {
    float delta = avgX - startAvgX;
    bool triggered = false;

    if (avgVelX > SWIPE_VELOCITY_THRESHOLD) {
      consecutiveRightFrames++;
      consecutiveLeftFrames = 0;
      if (consecutiveRightFrames >= 2) {
        printf("Right swipe (by velocity) detected.\n");
        switch_workspace(SWIPE_RIGHT);
        triggered = true;
        consecutiveRightFrames = 0;
      }
    } else if (avgVelX < -SWIPE_VELOCITY_THRESHOLD) {
      consecutiveLeftFrames++;
      consecutiveRightFrames = 0;
      if (consecutiveLeftFrames >= 2) {
        printf("Left swipe (by velocity) detected.\n");
        switch_workspace(SWIPE_LEFT);
        triggered = true;
        consecutiveLeftFrames = 0;
      }
    } else if (delta > SWIPE_THRESHOLD) {
      printf("Right swipe (by position) detected.\n");
      switch_workspace(SWIPE_RIGHT);
      triggered = true;
    } else if (delta < -SWIPE_THRESHOLD) {
      printf("Left swipe (by position) detected.\n");
      switch_workspace(SWIPE_LEFT);
      triggered = true;
    }

    if (triggered) {
      lastSwipeTime = timestamp;
      swiping = false;
    }
  }

  pthread_mutex_unlock(&gestureMutex);
}

int main(void) {
  if (!get_aerospace_path()) {
    return EXIT_FAILURE;
  }

  void *mtlib = dlopen("/System/Library/PrivateFrameworks/"
                       "MultitouchSupport.framework/MultitouchSupport",
                       RTLD_NOW);
  if (!mtlib) {
    fprintf(stderr, "Error: Unable to load MultitouchSupport framework.\n");
    return EXIT_FAILURE;
  }

  MTDeviceRef (*MTDeviceCreateDefault)(void) =
      dlsym(mtlib, "MTDeviceCreateDefault");
  int (*MTDeviceStart)(MTDeviceRef, int) = dlsym(mtlib, "MTDeviceStart");
  void (*MTDeviceStop)(MTDeviceRef) = dlsym(mtlib, "MTDeviceStop");
  void (*MTRegisterContactFrameCallback)(MTDeviceRef, MTContactCallbackFunction,
                                         void *) =
      dlsym(mtlib, "MTRegisterContactFrameCallback");

  if (!MTDeviceCreateDefault || !MTDeviceStart || !MTDeviceStop ||
      !MTRegisterContactFrameCallback) {
    fprintf(
        stderr,
        "Error: Failed to load required functions from MultitouchSupport.\n");
    dlclose(mtlib);
    return EXIT_FAILURE;
  }

  MTDeviceRef device = MTDeviceCreateDefault();
  if (!device) {
    fprintf(stderr, "Error: Failed to create MTDevice instance.\n");
    dlclose(mtlib);
    return EXIT_FAILURE;
  }

  MTRegisterContactFrameCallback(device, gestureCallback, NULL);

  if (MTDeviceStart(device, 0) != 0) {
    fprintf(stderr, "Error: Failed to start MTDevice.\n");
    dlclose(mtlib);
    return EXIT_FAILURE;
  }

  printf("Listening for three-finger swipes...\n");

  CFRunLoopRun();

  MTDeviceStop(device);
  dlclose(mtlib);
  return EXIT_SUCCESS;
}
