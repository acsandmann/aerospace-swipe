#define AEROSPACE_H

#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>

typedef struct aerospace aerospace;

aerospace* aerospace_new(const char* socketPath);

int aerospace_is_initialized(aerospace* client);

void aerospace_close(aerospace* client);

void aerospace_reconnect(aerospace* client);

void aerospace_set_auto_reconnect(aerospace* client, bool enabled);

void aerospace_set_reconnect_params(aerospace* client, int max_attempts, int delay_ms);

char* aerospace_switch(aerospace* client, const char* direction);

char* aerospace_workspace(aerospace* client, int wrap_around, const char* ws_command, const char* stdin_payload);

char* aerospace_list_workspaces(aerospace* client, bool include_empty);
