// n1x_fps: minimal Vulkan implicit layer that counts presented frames.
// Every 0.5 s it writes "<fps> <avg frame ms> <comm>\n" to /dev/shm/n1x-fps-<uid>/<pid>
// (or ~/.cache/n1x-fps/<pid> if /dev/shm is not usable). The Power Deck reads those files.
// No Vulkan headers needed; only the few layer-interface structs are declared here.
// Build: gcc -O2 -shared -fPIC -fvisibility=hidden -o libn1x_fps.so n1x_fps.c
// Disable for one program: DISABLE_N1X_FPS=1
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define EXPORT __attribute__((visibility("default")))
typedef void (*vfn)(void);
typedef vfn (*gpa_fn)(void *handle, const char *name);
typedef int32_t VkResult;

typedef struct { int32_t sType; const void *pNext; } base_t;
typedef struct link { struct link *pNext; gpa_fn nextGIPA; gpa_fn nextOther; } link_t;   // instance: GPDPA, device: GDPA
typedef struct { int32_t sType; const void *pNext; int32_t function; link_t *pLayerInfo; } layer_ci_t;
typedef struct { int32_t sType; void *pNext; uint32_t version; gpa_fn gipa; gpa_fn gdpa; gpa_fn gpdpa; } negotiate_t;

#define ST_LOADER_INSTANCE_CI 47
#define ST_LOADER_DEVICE_CI 48
#define LAYER_LINK_INFO 0
#define KEY(h) (*(void **)(h))          // loader dispatch pointer, shared by a device and its queues

typedef struct { void *key; gpa_fn gpa; vfn destroy; vfn present; } ent_t;
#define N 32
static ent_t inst[N], dev[N];
static volatile int lock_;
static void lock(void) { while (__atomic_test_and_set(&lock_, __ATOMIC_ACQUIRE)) ; }
static void unlock(void) { __atomic_clear(&lock_, __ATOMIC_RELEASE); }

static ent_t *find(ent_t *t, void *key) {
    for (int i = 0; i < N; i++) if (t[i].key == key) return &t[i];
    return NULL;
}
static void put(ent_t *t, ent_t e) {
    lock();
    ent_t *s = find(t, e.key);
    if (!s) s = find(t, NULL);
    if (s) *s = e;
    unlock();
}
static ent_t get(ent_t *t, void *key) {
    ent_t e = {0};
    lock();
    ent_t *s = find(t, key);
    if (s) e = *s;
    unlock();
    return e;
}
static void drop(ent_t *t, void *key) {
    lock();
    ent_t *s = find(t, key);
    if (s) memset(s, 0, sizeof *s);
    unlock();
}

// ---- frame counter
static char path[256], comm[32];
static double t_last;
static unsigned frames;
static volatile int cnt_lock;

static void setup_path(void) {
    char dir[200];
    snprintf(dir, sizeof dir, "/dev/shm/n1x-fps-%u", (unsigned)getuid());
    if (mkdir(dir, 0700) != 0 && access(dir, W_OK) != 0) {
        const char *h = getenv("HOME");
        snprintf(dir, sizeof dir, "%s/.cache", h ? h : "/tmp");
        mkdir(dir, 0700);
        snprintf(dir, sizeof dir, "%s/.cache/n1x-fps", h ? h : "/tmp");
        mkdir(dir, 0700);
    }
    snprintf(path, sizeof path, "%s/%d", dir, (int)getpid());
    int fd = open("/proc/self/comm", O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        ssize_t n = read(fd, comm, sizeof comm - 1);
        if (n > 0) comm[n] = 0;
        close(fd);
    }
    for (char *c = comm; *c; c++) if (*c == '\n' || *c == ' ') *c = (*c == ' ') ? '_' : 0;
    if (!comm[0]) strcpy(comm, "?");
}

static void frame(void) {
    if (__atomic_test_and_set(&cnt_lock, __ATOMIC_ACQUIRE)) return;   // another thread is counting
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = ts.tv_sec + ts.tv_nsec * 1e-9;
    if (!path[0]) { setup_path(); t_last = now; frames = 0; }
    frames++;
    double dt = now - t_last;
    if (dt >= 0.5) {
        char buf[96];
        int n = snprintf(buf, sizeof buf, "%.1f %.2f %s\n", frames / dt, dt * 1000.0 / frames, comm);
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (fd >= 0) { if (write(fd, buf, n) < 0) {} close(fd); }
        t_last = now;
        frames = 0;
    }
    __atomic_clear(&cnt_lock, __ATOMIC_RELEASE);
}

// ---- intercepted entry points
static vfn n1x_GetInstanceProcAddr(void *instance, const char *name);
static vfn n1x_GetDeviceProcAddr(void *device, const char *name);

static VkResult n1x_QueuePresentKHR(void *queue, const void *info) {
    ent_t e = get(dev, KEY(queue));
    frame();
    return e.present ? ((VkResult (*)(void *, const void *))e.present)(queue, info) : -3;
}

static void n1x_DestroyDevice(void *device, const void *alloc) {
    if (!device) return;
    ent_t e = get(dev, KEY(device));
    drop(dev, KEY(device));
    if (e.destroy) ((void (*)(void *, const void *))e.destroy)(device, alloc);
}

static void n1x_DestroyInstance(void *instance, const void *alloc) {
    if (!instance) return;
    ent_t e = get(inst, KEY(instance));
    drop(inst, KEY(instance));
    if (e.destroy) ((void (*)(void *, const void *))e.destroy)(instance, alloc);
    if (path[0]) unlink(path);
}

static layer_ci_t *link_info(const base_t *ci, int32_t stype) {
    for (const base_t *p = ci->pNext; p; p = p->pNext)
        if (p->sType == stype && ((const layer_ci_t *)p)->function == LAYER_LINK_INFO)
            return (layer_ci_t *)p;
    return NULL;
}

static VkResult n1x_CreateInstance(const base_t *ci, const void *alloc, void **pInstance) {
    layer_ci_t *li = link_info(ci, ST_LOADER_INSTANCE_CI);
    if (!li || !li->pLayerInfo) return -3;                       // VK_ERROR_INITIALIZATION_FAILED
    gpa_fn next = li->pLayerInfo->nextGIPA;
    li->pLayerInfo = li->pLayerInfo->pNext;
    VkResult (*create)(const base_t *, const void *, void **) = (void *)next(NULL, "vkCreateInstance");
    if (!create) return -3;
    VkResult r = create(ci, alloc, pInstance);
    if (r == 0)
        put(inst, (ent_t){KEY(*pInstance), next, next(*pInstance, "vkDestroyInstance"), NULL});
    return r;
}

static VkResult n1x_CreateDevice(void *phys, const base_t *ci, const void *alloc, void **pDevice) {
    layer_ci_t *li = link_info(ci, ST_LOADER_DEVICE_CI);
    if (!li || !li->pLayerInfo) return -3;
    gpa_fn gipa = li->pLayerInfo->nextGIPA, gdpa = li->pLayerInfo->nextOther;
    li->pLayerInfo = li->pLayerInfo->pNext;
    VkResult (*create)(void *, const base_t *, const void *, void **) = (void *)gipa(NULL, "vkCreateDevice");
    if (!create) return -3;
    VkResult r = create(phys, ci, alloc, pDevice);
    if (r == 0)
        put(dev, (ent_t){KEY(*pDevice), gdpa, gdpa(*pDevice, "vkDestroyDevice"), gdpa(*pDevice, "vkQueuePresentKHR")});
    return r;
}

static vfn n1x_GetDeviceProcAddr(void *device, const char *name) {
    if (!strcmp(name, "vkGetDeviceProcAddr")) return (vfn)n1x_GetDeviceProcAddr;
    if (!strcmp(name, "vkDestroyDevice")) return (vfn)n1x_DestroyDevice;
    ent_t e = get(dev, KEY(device));
    if (!strcmp(name, "vkQueuePresentKHR") && e.present) return (vfn)n1x_QueuePresentKHR;
    return e.gpa ? e.gpa(device, name) : NULL;
}

static vfn n1x_GetInstanceProcAddr(void *instance, const char *name) {
    if (!strcmp(name, "vkGetInstanceProcAddr")) return (vfn)n1x_GetInstanceProcAddr;
    if (!strcmp(name, "vkCreateInstance")) return (vfn)n1x_CreateInstance;
    if (!strcmp(name, "vkDestroyInstance")) return (vfn)n1x_DestroyInstance;
    if (!strcmp(name, "vkCreateDevice")) return (vfn)n1x_CreateDevice;
    if (!strcmp(name, "vkGetDeviceProcAddr")) return (vfn)n1x_GetDeviceProcAddr;
    if (!strcmp(name, "vkDestroyDevice")) return (vfn)n1x_DestroyDevice;
    if (!instance) return NULL;
    ent_t e = get(inst, KEY(instance));
    return e.gpa ? e.gpa(instance, name) : NULL;
}

EXPORT VkResult vkNegotiateLoaderLayerInterfaceVersion(negotiate_t *n) {
    if (!n || n->sType != 1) return -3;
    if (n->version > 2) n->version = 2;
    n->gipa = n1x_GetInstanceProcAddr;
    n->gdpa = n1x_GetDeviceProcAddr;
    n->gpdpa = NULL;
    return 0;
}
