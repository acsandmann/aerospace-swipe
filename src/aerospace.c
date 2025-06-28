#include <errno.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include "aerospace.h"
#include "cJSON.h"

#define DEFAULT_MAX_BUFFER_SIZE 4096

static const char* ERROR_SOCKET_CREATE = "Failed to create Unix domain socket";
static const char* ERROR_SOCKET_CONNECT_FMT = "Failed to connect to socket at %s";
static const char* ERROR_SOCKET_SEND = "Failed to send data through socket";
static const char* ERROR_SOCKET_RECEIVE = "Failed to receive data from socket";
static const char* ERROR_SOCKET_CLOSE = "Failed to close socket connection";
static const char* ERROR_SOCKET_NOT_CONN = "Socket is not connected";
static const char* ERROR_JSON_CREATE = "Failed to create JSON object/array";
static const char* ERROR_JSON_PRINT = "Failed to print JSON to string";
static const char* ERROR_JSON_DECODE = "Failed to decode JSON response";
static const char* ERROR_RESPONSE_FORMAT = "Response does not contain valid %s field";
static const char* WARN_CLI_FALLBACK = "Warning: Failed to connect to socket at %s: %s (errno %d). Falling back to CLI.";

struct aerospace {
	int fd;
	char* socket_path;
	bool use_cli_fallback;
};

static void fatal_error(const char* fmt, ...)
{
	va_list args;
	va_start(args, fmt);
	fprintf(stderr, "Fatal Error: ");
	vfprintf(stderr, fmt, args);
	if (errno != 0)
		fprintf(stderr, ": %s (errno %d)", strerror(errno), errno);
	fprintf(stderr, "\n");
	va_end(args);
	exit(EXIT_FAILURE);
}

static ssize_t write_all(int fd, const char* restrict buf, size_t count)
{
	const char* p = buf;
	size_t remaining = count;
	while (remaining > 0) {
		ssize_t ret = write(fd, p, remaining);
		if (ret < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (ret == 0) {
			errno = EPIPE;
			return -1;
		}
		p += ret;
		remaining -= ret;
	}
	return (ssize_t)count;
}

static cJSON* decode_response(const char* response_str)
{
	if (!response_str) {
		fprintf(stderr, "%s: Input string is NULL\n", ERROR_JSON_DECODE);
		return NULL;
	}
	cJSON* json = cJSON_Parse(response_str);
	if (!json) {
		fprintf(stderr, "%s: %s\n", ERROR_JSON_DECODE, cJSON_GetErrorPtr());
	}
	return json;
}

static char* get_default_socket_path(void)
{
	uid_t uid = getuid();
	struct passwd* pw = getpwuid(uid);

	if (uid == 0) {
		const char* sudo_user = getenv("SUDO_USER");
		if (sudo_user) {
			struct passwd* pw_temp = getpwnam(sudo_user);
			if (pw_temp)
				pw = pw_temp;
		} else {
			const char* user_env = getenv("USER");
			if (user_env && strcmp(user_env, "root") != 0) {
				struct passwd* pw_temp = getpwnam(user_env);
				if (pw_temp)
					pw = pw_temp;
			}
		}
	}

	if (!pw)
		fatal_error("Unable to determine user information for default socket path");

	const char* username = pw->pw_name;
	size_t len = snprintf(NULL, 0, "/tmp/bobko.aerospace-%s.sock", username);
	char* path = malloc(len + 1);
	snprintf(path, len + 1, "/tmp/bobko.aerospace-%s.sock", username);
	return path;
}

static char* execute_cli_command(const char* command_string)
{
	FILE* pipe = popen(command_string, "r");
	if (!pipe) {
		fatal_error("popen() failed for command '%s'", command_string);
	}

	size_t capacity = DEFAULT_MAX_BUFFER_SIZE;
	char* output = malloc(capacity + 1);
	if (!output) {
		pclose(pipe);
		fatal_error("Failed to allocate buffer for CLI output");
	}

	size_t total_read = 0;
	size_t nread;

	while ((nread = fread(output + total_read, 1, capacity - total_read, pipe)) > 0) {
		total_read += nread;
		if (total_read >= capacity) {
			capacity *= 2;
			char* new_output = realloc(output, capacity + 1);
			if (!new_output) {
				free(output);
				pclose(pipe);
				fatal_error("Failed to reallocate buffer for CLI output");
			}
			output = new_output;
		}
	}

	output[total_read] = '\0';

	int status = pclose(pipe);
	if (status != 0) {
		if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
			fprintf(stderr, "Warning: CLI command failed with exit code %d: %s\n", WEXITSTATUS(status), command_string);
		} else if (status == -1) {
			fprintf(stderr, "Warning: pclose failed: %s\n", strerror(errno));
		}
	}

	if (total_read > 0 && output[total_read - 1] == '\n') {
		output[total_read - 1] = '\0';
	}

	return output;
}

static char* execute_aerospace_command(aerospace* client, const char** args, int arg_count, const char* stdin_payload, const char* expected_output_field)
{
	if (!client || !args || arg_count == 0) {
		errno = EINVAL;
		fprintf(stderr, "execute_aerospace_command: Invalid arguments\n");
		return NULL;
	}

	if (client->use_cli_fallback) {
		size_t total_len = strlen("aerospace") + 1;
		for (int i = 0; i < arg_count; i++) {
			total_len += strlen(args[i]) + 1;
		}

		char* cli_command_base = malloc(total_len);
		if (!cli_command_base) {
			fatal_error("Failed to allocate memory for CLI command");
		}
		strcpy(cli_command_base, "aerospace");
		for (int i = 0; i < arg_count; i++) {
			strcat(cli_command_base, " ");
			strcat(cli_command_base, args[i]);
		}

		char* final_command;
		if (stdin_payload && strlen(stdin_payload) > 0) {
			const char* format = "echo '%s' | %s";
			size_t len = snprintf(NULL, 0, format, stdin_payload, cli_command_base);
			final_command = malloc(len + 1);
			snprintf(final_command, len + 1, format, stdin_payload, cli_command_base);
			free(cli_command_base);
		} else {
			final_command = cli_command_base;
		}

		char* result = execute_cli_command(final_command);
		free(final_command);
		return result;
	}

	cJSON* args_array = cJSON_CreateArray();
	for (int i = 0; i < arg_count; i++) {
		cJSON_AddItemToArray(args_array, cJSON_CreateString(args[i]));
	}

	cJSON* query = cJSON_CreateObject();
	if (!cJSON_AddStringToObject(query, "command", args[0]) || !cJSON_AddItemToObject(query, "args", args_array) || !cJSON_AddStringToObject(query, "stdin", stdin_payload ? stdin_payload : "")) {
		cJSON_Delete(query);
		fatal_error(ERROR_JSON_CREATE);
	}

	char* json_str = cJSON_PrintUnformatted(query);
	cJSON_Delete(query);
	write_all(client->fd, json_str, strlen(json_str) + 1);
	free(json_str);

	char* response_str = malloc(DEFAULT_MAX_BUFFER_SIZE + 1);
	ssize_t bytes_read = read(client->fd, response_str, DEFAULT_MAX_BUFFER_SIZE);
	if (bytes_read < 0) {
		free(response_str);
		fatal_error("%s", ERROR_SOCKET_RECEIVE);
	}
	response_str[bytes_read] = '\0';

	cJSON* response_json = decode_response(response_str);
	free(response_str);
	if (!response_json) return NULL;

	int exitCode = -1;
	cJSON* exitCodeItem = cJSON_GetObjectItemCaseSensitive(response_json, "exitCode");
	if (cJSON_IsNumber(exitCodeItem)) {
		exitCode = exitCodeItem->valueint;
	} else {
		fprintf(stderr, ERROR_RESPONSE_FORMAT, "exitCode\n");
		cJSON_Delete(response_json);
		return NULL;
	}

	char* result = NULL;
	if (exitCode != 0) {
		cJSON* output_item = cJSON_GetObjectItemCaseSensitive(response_json, "stderr");
		if (cJSON_IsString(output_item) && output_item->valuestring) {
			result = strdup(output_item->valuestring);
		}
	} else if (expected_output_field) {
		cJSON* output_item = cJSON_GetObjectItemCaseSensitive(response_json, expected_output_field);
		if (cJSON_IsString(output_item) && output_item->valuestring) {
			result = strdup(output_item->valuestring);
		}
	}

	cJSON_Delete(response_json);
	return result;
}

aerospace* aerospace_new(const char* socketPath)
{
	aerospace* client = malloc(sizeof(aerospace));
	client->fd = -1;
	client->use_cli_fallback = false;

	if (socketPath)
		client->socket_path = strdup(socketPath);
	else
		client->socket_path = get_default_socket_path();

	errno = 0;
	client->fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (client->fd < 0) {
		int socket_errno = errno;
		free(client->socket_path);
		free(client);
		errno = socket_errno;
		fatal_error("%s", ERROR_SOCKET_CREATE);
	}

	struct sockaddr_un addr;
	memset(&addr, 0, sizeof(struct sockaddr_un));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, client->socket_path, sizeof(addr.sun_path) - 1);
	addr.sun_path[sizeof(addr.sun_path) - 1] = '\0';

	errno = 0;
	if (connect(client->fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
		int connect_errno = errno;
		fprintf(stderr, WARN_CLI_FALLBACK, client->socket_path, strerror(connect_errno), connect_errno);
		close(client->fd);
		client->fd = -1;
		client->use_cli_fallback = true;
	}

	return client;
}

int aerospace_is_initialized(aerospace* client)
{
	return (client && (client->fd >= 0 || client->use_cli_fallback));
}

void aerospace_close(aerospace* client)
{
	if (client) {
		if (client->fd >= 0) {
			errno = 0;
			if (close(client->fd) < 0) {
				fprintf(stderr, "%s: %s (errno %d)\n", ERROR_SOCKET_CLOSE, strerror(errno), errno);
			}
			client->fd = -1;
		}
		free(client->socket_path);
		client->socket_path = NULL;
		free(client);
	}
}

char* aerospace_switch(aerospace* client, const char* direction)
{
	return aerospace_workspace(client, 0, direction, "");
}

char* aerospace_workspace(aerospace* client, int wrap_around, const char* ws_command,
	const char* stdin_payload)
{
	const char* args[3];
	int arg_count = 0;
	args[arg_count++] = "workspace";
	args[arg_count++] = ws_command;
	if (wrap_around) {
		args[arg_count++] = "--wrap-around";
	}
	return execute_aerospace_command(client, args, arg_count, stdin_payload, NULL);
}

char* aerospace_list_workspaces(aerospace* client, bool include_empty)
{
	const char* args[5];
	int arg_count = 0;
	args[arg_count++] = "list-workspaces";
	args[arg_count++] = "--monitor";
	args[arg_count++] = "focused";
	if (!include_empty) {
		args[arg_count++] = "--empty";
		args[arg_count++] = "no";
	}

	return execute_aerospace_command(client, args, arg_count, "", "stdout");
}
