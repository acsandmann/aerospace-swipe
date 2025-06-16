#include <errno.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "aerospace.h"
#include "cJSON.h"

#define DEFAULT_MAX_BUFFER_SIZE 2048
#define MAX_RECONNECT_ATTEMPTS 1
#define RECONNECT_DELAY_MS 0

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
static const char* ERROR_MAX_RECONNECT = "Maximum reconnection attempts exceeded";

struct aerospace {
	int fd;
	char* socket_path;
	bool auto_reconnect_enabled;
	int max_reconnect_attempts;
	int reconnect_delay_ms;
};

static void fatal_error(const char* fmt, ...)
{
	va_list args;
	va_start(args, fmt);
	fprintf(stderr, "Fatal Error: ");
	vfprintf(stderr, fmt, args);
	if (errno != 0) fprintf(stderr, ": %s (errno %d)", strerror(errno), errno);
	fprintf(stderr, "\n");
	va_end(args);
	exit(EXIT_FAILURE);
}

static void sleep_ms(int milliseconds)
{
	struct timespec ts;
	ts.tv_sec = milliseconds / 1000;
	ts.tv_nsec = (milliseconds % 1000) * 1000000;
	nanosleep(&ts, NULL);
}

static bool is_connection_error(int error_code)
{
	return (error_code == EPIPE || error_code == ECONNRESET || error_code == ECONNABORTED || error_code == ENOTCONN
		|| error_code == EBADF);
}

static int aerospace_reconnect_internal(aerospace* client)
{
	if (!client) return -1;

	if (client->fd >= 0) {
		close(client->fd);
		client->fd = -1;
	}

	client->fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (client->fd < 0) { return -1; }

	struct sockaddr_un addr;
	memset(&addr, 0, sizeof(struct sockaddr_un));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, client->socket_path, sizeof(addr.sun_path) - 1);
	addr.sun_path[sizeof(addr.sun_path) - 1] = '\0';

	if (connect(client->fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
		close(client->fd);
		client->fd = -1;
		return -1;
	}

	return 0;
}

static int aerospace_ensure_connection(aerospace* client)
{
	if (!client) return -1;

	if (aerospace_is_initialized(client)) return 0;

	if (!client->auto_reconnect_enabled) {
		errno = EBADF;
		return -1;
	}

	for (int attempt = 0; attempt < client->max_reconnect_attempts; attempt++) {
		if (attempt > 0) { sleep_ms(client->reconnect_delay_ms); }

		if (aerospace_reconnect_internal(client) == 0) {
			fprintf(stderr, "Successfully reconnected to aerospace socket (attempt %d/%d)\n", attempt + 1,
				client->max_reconnect_attempts);
			return 0;
		}

		fprintf(stderr, "Reconnection attempt %d/%d failed\n", attempt + 1, client->max_reconnect_attempts);
	}

	errno = ECONNREFUSED;
	return -1;
}

static ssize_t write_all(int fd, const char* restrict buf, size_t count)
{
	const char* p = buf;
	size_t remaining = count;
	while (remaining > 0) {
		ssize_t ret = write(fd, p, remaining);
		if (ret < 0) {
			if (errno == EINTR) continue;
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
	if (!json) { fprintf(stderr, "%s: %s\n", ERROR_JSON_DECODE, cJSON_GetErrorPtr()); }
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
			if (pw_temp) pw = pw_temp;
		} else {
			const char* user_env = getenv("USER");
			if (user_env && strcmp(user_env, "root") != 0) {
				struct passwd* pw_temp = getpwnam(user_env);
				if (pw_temp) pw = pw_temp;
			}
		}
	}

	if (!pw) fatal_error("Unable to determine user information for default socket path");

	const char* username = pw->pw_name;
	size_t len = snprintf(NULL, 0, "/tmp/bobko.aerospace-%s.sock", username);
	char* path = malloc(len + 1);
	snprintf(path, len + 1, "/tmp/bobko.aerospace-%s.sock", username);
	return path;
}

static ssize_t internal_aerospace_send(aerospace* client, cJSON* query)
{
	if (!query) {
		errno = EINVAL;
		fatal_error("internal_aerospace_send: query object is NULL");
	}

	char* json_str = cJSON_PrintUnformatted(query);
	if (!json_str) {
		cJSON_Delete(query);
		errno = 0;
		fatal_error("%s", ERROR_JSON_PRINT);
	}

	size_t len = strlen(json_str);
	size_t total_len = len + 1;
	char* send_buf = malloc(total_len + 1);
	snprintf(send_buf, total_len + 1, "%s\n", json_str);

	ssize_t bytes_sent = -1;
	int attempts = client->auto_reconnect_enabled ? client->max_reconnect_attempts : 1;

	for (int attempt = 0; attempt < attempts; attempt++) {
		if (attempt > 0) {
			if (aerospace_ensure_connection(client) != 0) break;
			sleep_ms(client->reconnect_delay_ms);
		} else {
			if (aerospace_ensure_connection(client) != 0) {
				if (!client->auto_reconnect_enabled) break;
				continue;
			}
		}

		errno = 0;
		bytes_sent = write_all(client->fd, send_buf, total_len);

		if (bytes_sent >= 0) break;

		if (!client->auto_reconnect_enabled || !is_connection_error(errno)) break;

		client->fd = -1;
	}

	free(send_buf);
	free(json_str);
	cJSON_Delete(query);

	if (bytes_sent < 0) {
		if (client->auto_reconnect_enabled && attempts > 1)
			fatal_error("%s", ERROR_MAX_RECONNECT);
		else
			fatal_error("%s", ERROR_SOCKET_SEND);
	}

	if ((size_t)bytes_sent != total_len) {
		errno = EIO;
		fatal_error("Incomplete send to socket");
	}

	return bytes_sent;
}

static char* internal_aerospace_receive(aerospace* client, size_t maxBytes)
{
	if (aerospace_ensure_connection(client) != 0) {
		if (client && client->auto_reconnect_enabled) {
			fatal_error("%s", ERROR_MAX_RECONNECT);
		} else {
			fatal_error("%s", ERROR_SOCKET_NOT_CONN);
		}
	}

	char* buffer = malloc(maxBytes + 1);
	ssize_t bytes_read = read(client->fd, buffer, maxBytes);

	if (bytes_read < 0 && client->auto_reconnect_enabled && is_connection_error(errno)) {
		free(buffer);
		client->fd = -1;
		if (aerospace_ensure_connection(client) == 0) {
			buffer = malloc(maxBytes + 1);
			bytes_read = read(client->fd, buffer, maxBytes);
		}
	}

	if (bytes_read < 0) {
		int read_errno = errno;
		free(buffer);
		errno = read_errno;
		fatal_error("%s", ERROR_SOCKET_RECEIVE);
	}

	buffer[bytes_read] = '\0';
	return buffer;
}

static cJSON* perform_query(aerospace* client, cJSON* query)
{
	internal_aerospace_send(client, query);

	char* response_str = internal_aerospace_receive(client, DEFAULT_MAX_BUFFER_SIZE);
	cJSON* response_json = decode_response(response_str);
	free(response_str);

	return response_json;
}

static char* execute_generic_command(aerospace* client, const char* command, cJSON* args_array, const char* stdin_value,
	const char* expected_output_field)
{
	if (!client || !command || !args_array) {
		errno = EINVAL;
		fprintf(stderr, "execute_generic_command: Invalid arguments\n");
		if (args_array) cJSON_Delete(args_array);
		return NULL;
	}

	cJSON* query = cJSON_CreateObject();
	if (!query) {
		cJSON_Delete(args_array);
		fatal_error(ERROR_JSON_CREATE);
	}

	if (!cJSON_AddStringToObject(query, "command", "") || !cJSON_AddItemToObject(query, "args", args_array)
		|| !cJSON_AddStringToObject(query, "stdin", stdin_value ? stdin_value : "")) {
		cJSON_Delete(query);
		fatal_error(ERROR_JSON_CREATE);
	}

	cJSON* response_json = perform_query(client, query);
	if (!response_json) return NULL;

	cJSON* exitCodeItem = cJSON_GetObjectItemCaseSensitive(response_json, "exitCode");
	int exitCode = -1;
	if (cJSON_IsNumber(exitCodeItem)) {
		exitCode = exitCodeItem->valueint;
	} else {
		fprintf(stderr, ERROR_RESPONSE_FORMAT, "exitCode");
		fprintf(stderr, "\n");
		cJSON_Delete(response_json);
		return NULL;
	}

	char* result = NULL;
	if (exitCode != 0) {
		cJSON* output_item = cJSON_GetObjectItemCaseSensitive(response_json, "stderr");
		if (!cJSON_IsString(output_item) || !output_item->valuestring) {
			fprintf(stderr, ERROR_RESPONSE_FORMAT, "stderr");
			fprintf(stderr, " (Exit code: %d)\n", exitCode);
		} else
			result = strdup(output_item->valuestring);
	} else {
		if (expected_output_field) {
			cJSON* output_item = cJSON_GetObjectItemCaseSensitive(response_json, expected_output_field);
			if (!cJSON_IsString(output_item) || !output_item->valuestring) {
				fprintf(stderr, ERROR_RESPONSE_FORMAT, expected_output_field);
				fprintf(stderr, " (Exit code: %d)\n", exitCode);
			} else {
				result = strdup(output_item->valuestring);
			}
		}
	}

	cJSON_Delete(response_json);
	return result;
}

static char* execute_workspace_command(aerospace* client, const char* cmd, int wrap_around, const char* stdin_value)
{
	if (!cmd) {
		fprintf(stderr, "execute_workspace_command: cmd cannot be NULL\n");
		return NULL;
	}

	cJSON* args = cJSON_CreateArray();
	if (!args) fatal_error(ERROR_JSON_CREATE);

	bool args_ok = true;
	args_ok &= (cJSON_AddItemToArray(args, cJSON_CreateString("workspace")) != NULL);
	args_ok &= (cJSON_AddItemToArray(args, cJSON_CreateString(cmd)) != NULL);
	if (wrap_around) { args_ok &= (cJSON_AddItemToArray(args, cJSON_CreateString("--wrap-around")) != NULL); }

	if (!args_ok) {
		cJSON_Delete(args);
		fatal_error(ERROR_JSON_CREATE);
	}

	return execute_generic_command(client, "workspace", args, stdin_value ? stdin_value : "", NULL);
}

aerospace* aerospace_new(const char* socketPath)
{
	aerospace* client = malloc(sizeof(aerospace));
	client->fd = -1;
	client->auto_reconnect_enabled = true;
	client->max_reconnect_attempts = MAX_RECONNECT_ATTEMPTS;
	client->reconnect_delay_ms = RECONNECT_DELAY_MS;

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
		char* failed_path = client->socket_path;
		close(client->fd);
		free(client);
		errno = connect_errno;
		fatal_error(ERROR_SOCKET_CONNECT_FMT, failed_path);
	}

	return client;
}

int aerospace_is_initialized(aerospace* client) { return (client && client->fd >= 0); }

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

void aerospace_reconnect(aerospace* client)
{
	if (aerospace_reconnect_internal(client) != 0) { fatal_error(ERROR_SOCKET_CONNECT_FMT, client->socket_path); }
}

void aerospace_set_auto_reconnect(aerospace* client, bool enabled)
{
	if (client) { client->auto_reconnect_enabled = enabled; }
}

void aerospace_set_reconnect_params(aerospace* client, int max_attempts, int delay_ms)
{
	if (client) {
		client->max_reconnect_attempts = max_attempts > 0 ? max_attempts : MAX_RECONNECT_ATTEMPTS;
		client->reconnect_delay_ms = delay_ms > 0 ? delay_ms : RECONNECT_DELAY_MS;
	}
}

char* aerospace_switch(aerospace* client, const char* direction)
{
	return execute_workspace_command(client, direction, 0, "");
}

char* aerospace_workspace(aerospace* client, int wrap_around, const char* ws_command, const char* stdin_payload)
{
	return execute_workspace_command(client, ws_command, wrap_around, stdin_payload);
}

char* aerospace_list_workspaces(aerospace* client, bool include_empty)
{
	cJSON* args = cJSON_CreateArray();
	if (!args) fatal_error(ERROR_JSON_CREATE);

	bool args_ok = true;
	args_ok &= (cJSON_AddItemToArray(args, cJSON_CreateString("list-workspaces")) != NULL);
	args_ok &= (cJSON_AddItemToArray(args, cJSON_CreateString("--monitor")) != NULL);
	args_ok &= (cJSON_AddItemToArray(args, cJSON_CreateString("focused")) != NULL);
	if (!include_empty) {
		args_ok &= (cJSON_AddItemToArray(args, cJSON_CreateString("--empty")) != NULL);
		args_ok &= (cJSON_AddItemToArray(args, cJSON_CreateString("no")) != NULL);
	}

	if (!args_ok) {
		cJSON_Delete(args);
		fatal_error(ERROR_JSON_CREATE);
	}

	return execute_generic_command(client, "list-workspaces", args, "", "stdout");
}
