#include <CoreFoundation/CoreFoundation.h>
#define CONFIG_H

#include "yyjson.h"
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
	float distance_pct; // distance
	float velocity_pct; // velocity
	float settle_factor;
	float min_step;
	float min_travel;
	float min_step_fast;
	float min_travel_fast;
	float palm_disp;
	CFTimeInterval palm_age;
	float palm_velocity;
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
	config.distance_pct = 0.12f; // ≥12 % travel triggers
	config.velocity_pct = 0.50f; // ≥0.50 × w pts / s triggers
	config.settle_factor = 0.15f; // ≤15 % of flick speed -> flick ended
	config.min_step = 0.005f;
	config.min_travel = 0.015f;
	config.min_step_fast = 0.0f;
	config.min_travel_fast = 0.006f;
	config.palm_disp = 0.025; // 2.5% pad from origin
	config.palm_age = 0.06; // 60ms before judgment
	config.palm_velocity = 0.1; // 10% of pad dimension per second
	config.swipe_left = "prev";
	config.swipe_right = "next";
	return config;
}

static int read_file_to_buffer(const char* path, char** out, size_t* size)
{
	FILE* file = fopen(path, "rb");
	if (!file)
		return 0;

	struct stat st;
	if (stat(path, &st) != 0) {
		fclose(file);
		return 0;
	}
	*size = st.st_size;

	*out = (char*)malloc(*size + 1);
	if (!*out) {
		fclose(file);
		return 0;
	}

	fread(*out, 1, *size, file);
	(*out)[*size] = '\0';
	fclose(file);
	return 1;
}

static Config load_config()
{
	Config config = default_config();

	char* buffer = NULL;
	size_t buffer_size = 0;
	const char* paths[] = { "./config.json", NULL };

	char fallback_path[512];
	struct passwd* pw = getpwuid(getuid());
	if (pw) {
		snprintf(fallback_path, sizeof(fallback_path),
			"%s/.config/aerospace-swipe/config.json", pw->pw_dir);
		paths[1] = fallback_path;
	}

	for (int i = 0; i < 2; ++i) {
		if (paths[i] && read_file_to_buffer(paths[i], &buffer, &buffer_size)) {
			printf("Loaded config from: %s\n", paths[i]);
			break;
		}
	}

	if (!buffer) {
		fprintf(stderr, "Using default configuration.\n");
		return config;
	}

	yyjson_doc* doc = yyjson_read(buffer, buffer_size, 0);
	free(buffer);
	if (!doc) {
		fprintf(stderr, "Failed to parse config JSON. Using defaults.\n");
		return config;
	}

	yyjson_val* root = yyjson_doc_get_root(doc);
	yyjson_val* item;

	item = yyjson_obj_get(root, "natural_swipe");
	if (item && yyjson_is_bool(item))
		config.natural_swipe = yyjson_get_bool(item);

	item = yyjson_obj_get(root, "wrap_around");
	if (item && yyjson_is_bool(item))
		config.wrap_around = yyjson_get_bool(item);

	item = yyjson_obj_get(root, "haptic");
	if (item && yyjson_is_bool(item))
		config.haptic = yyjson_get_bool(item);

	item = yyjson_obj_get(root, "skip_empty");
	if (item && yyjson_is_bool(item))
		config.skip_empty = yyjson_get_bool(item);

	item = yyjson_obj_get(root, "fingers");
	if (item && yyjson_is_int(item))
		config.fingers = (int)yyjson_get_int(item);

	item = yyjson_obj_get(root, "distance_pct");
	if (item && yyjson_is_real(item))
		config.distance_pct = (float)yyjson_get_real(item);

	item = yyjson_obj_get(root, "velocity_pct");
	if (item && yyjson_is_real(item))
		config.velocity_pct = (float)yyjson_get_real(item);

	item = yyjson_obj_get(root, "settle_factor");
	if (item && yyjson_is_real(item))
		config.settle_factor = (float)yyjson_get_real(item);

	config.swipe_left = config.natural_swipe ? "next" : "prev";
	config.swipe_right = config.natural_swipe ? "prev" : "next";

	yyjson_doc_free(doc);
	return config;
}
