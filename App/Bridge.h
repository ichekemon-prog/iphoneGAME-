#include <stdbool.h>
bool probe_start(const char *path, const char *host, const char *runner, const char *self_bundle);
void probe_set_tap_point(double x, double y);
void probe_stop(void);
bool probe_running(void);
char *probe_status(void);
void probe_free_string(char *p);
