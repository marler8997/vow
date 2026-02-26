// Stub implementations of dl* functions.
// These are never called — the real implementations come from the system's
// libc at runtime. This file exists only so `zig cc -shared` can produce
// a .so that exports these symbols with a custom SONAME marker.
void *dlopen(const char *filename, int flags) { __builtin_trap(); }
void *dlsym(void *handle, const char *symbol) { __builtin_trap(); }
int dlclose(void *handle) { __builtin_trap(); }
char *dlerror(void) { __builtin_trap(); }
