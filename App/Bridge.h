#include <stdbool.h>
bool probe_start(const char *path, const char *host, const char *bundle);
void probe_stop(void);
bool probe_running(void);
bool probe_holding(void);
void probe_mark_cellular_restored(void);
char *probe_status(void);
void probe_free_string(char *p);
