#define CONFIG_H

#include "cJSON.h"
#include <pwd.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
	bool natural_swipe;
	bool wrap_around;
	bool haptic;
	bool skip_empty;
	int fingers;
	float swipe_cooldown;
	float swipe_threshold; // distance
	float velocity_swipe_threshold; // velocity
	int velocity_frames_threshold; // distance
	const char* swipe_left;
	const char* swipe_right;
} Config;

static Config default_config()
{
	Config config;
	config.natural_swipe = false;
	config.wrap_around = true;
	config.haptic = false;
	config.skip_empty = true;
	config.fingers = 3;
	config.swipe_cooldown = 0.3f;
	config.swipe_threshold = 0.15f;
	config.velocity_swipe_threshold = 0.75f;
	config.velocity_frames_threshold = 2;
	config.swipe_left = "prev";
	config.swipe_right = "next";
	return config;
}

static int read_file_to_buffer(const char* path, char** out)
{
	FILE* file = fopen(path, "rb");
	if (!file)
		return 0;

	struct stat st;
	if (stat(path, &st) != 0) {
		fclose(file);
		return 0;
	}

	*out = (char*)malloc(st.st_size + 1);
	if (!*out) {
		fclose(file);
		return 0;
	}

	fread(*out, 1, st.st_size, file);
	(*out)[st.st_size] = '\0';
	fclose(file);
	return 1;
}

static Config load_config()
{
	Config config = default_config();

	char* buffer = NULL;
	const char* paths[] = { "./config.json", NULL };

	char fallback_path[512];
	struct passwd* pw = getpwuid(getuid());
	if (pw) {
		snprintf(fallback_path, sizeof(fallback_path),
			"%s/.config/aerospace-swipe/config.json", pw->pw_dir);
		paths[1] = fallback_path;
	}

	for (int i = 0; i < 2; ++i) {
		if (paths[i] && read_file_to_buffer(paths[i], &buffer)) {
			printf("Loaded config from: %s\n", paths[i]);
			break;
		}
	}

	if (!buffer) {
		fprintf(stderr, "Using default configuration.\n");
		return config;
	}

	cJSON* root = cJSON_Parse(buffer);
	free(buffer);
	if (!root) {
		fprintf(stderr, "Failed to parse config JSON. Using defaults.\n");
		return config;
	}

	cJSON* item;

	item = cJSON_GetObjectItem(root, "natural_swipe");
	if (cJSON_IsBool(item))
		config.natural_swipe = cJSON_IsTrue(item);

	item = cJSON_GetObjectItem(root, "wrap_around");
	if (cJSON_IsBool(item))
		config.wrap_around = cJSON_IsTrue(item);

	item = cJSON_GetObjectItem(root, "haptic");
	if (cJSON_IsBool(item))
		config.haptic = cJSON_IsTrue(item);

	item = cJSON_GetObjectItem(root, "skip_empty");
	if (cJSON_IsBool(item))
		config.skip_empty = cJSON_IsTrue(item);

	item = cJSON_GetObjectItem(root, "fingers");
	if (cJSON_IsNumber(item))
		config.fingers = item->valueint;

	item = cJSON_GetObjectItem(root, "swipe_cooldown");
	if (cJSON_IsNumber(item))
		config.swipe_cooldown = (float)item->valuedouble;

	item = cJSON_GetObjectItem(root, "swipe_threshold");
	if (cJSON_IsNumber(item))
		config.swipe_threshold = (float)item->valuedouble;

	item = cJSON_GetObjectItem(root, "velocity_swipe_threshold");
	if (cJSON_IsNumber(item))
		config.velocity_swipe_threshold = (float)item->valuedouble;

	item = cJSON_GetObjectItem(root, "velocity_frames_threshold");
	if (cJSON_IsNumber(item))
		config.velocity_frames_threshold = item->valueint;

	config.swipe_left = config.natural_swipe ? "next" : "prev";
	config.swipe_right = config.natural_swipe ? "prev" : "next";

	cJSON_Delete(root);
	return config;
}
