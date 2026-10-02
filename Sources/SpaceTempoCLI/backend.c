// MIT licensed. Independently implemented from observed stock Apple
// instructions.
#include "backend.h"
#include "timing.h"
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach-o/dyld_images.h>
#include <mach-o/loader.h>
#include <mach/arm/thread_status.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <unistd.h>

#define DOCK "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
#define BLOCK_SIZE 140
#define MAGIC UINT64_C(0x535454454d504f31)
static const char expected_hash[] =
    "b704affba65f732ffd6676c3bb22c94abc737ee73af8bdf29a5ef02650cde33e";
typedef struct {
  uint32_t slice, size, preamble, constant;
  uint8_t uuid[16];
} Profile;
static const Profile profiles[] = {
    {0x4000,
     0x49e880,
     0xde2dc,
     0x308a68,
     {0x3b, 0xdf, 0x6a, 0x3b, 0x86, 0x6b, 0x3c, 0x07, 0x92, 0x0c, 0xe9, 0xe7,
      0xfb, 0x57, 0xb5, 0x6b}},
    {0x4a4000,
     0x48a700,
     0xd9edc,
     0x2f41c8,
     {0x82, 0x19, 0xe2, 0x78, 0x73, 0xec, 0x33, 0x2f, 0xbd, 0xf4, 0xfc, 0x95,
      0x0a, 0xb0, 0xf8, 0x84}}};
typedef struct {
  double retention, gain;
  uint64_t magic, code, pid, start_sec, start_usec;
  double factor;
  uint8_t uuid[16];
} Scratch;
typedef struct {
  uint8_t *data;
  size_t size;
} Disk;
typedef struct {
  task_t task;
  pid_t pid;
  struct proc_bsdinfo proc;
  mach_vm_address_t base, code;
  const Profile *profile;
  uint8_t stock[BLOCK_SIZE], current[BLOCK_SIZE];
  mach_vm_address_t scratch;
  Scratch meta;
  int patched;
} Target;
static int fail(const char *message) {
  fprintf(stderr, "SpaceTempo: %s\n", message);
  return 1;
}
static int read_remote(task_t t, mach_vm_address_t a, void *b, size_t n) {
  mach_vm_size_t got = 0;
  return mach_vm_read_overwrite(t, a, n, (mach_vm_address_t)b, &got) ==
             KERN_SUCCESS &&
         got == n;
}
static int disk_load(const char *path, Disk *d) {
  memset(d, 0, sizeof(*d));
  FILE *f = fopen(path, "rb");
  if (!f)
    return 0;
  if (fseek(f, 0, SEEK_END) || ftell(f) < 0) {
    fclose(f);
    return 0;
  }
  d->size = (size_t)ftell(f);
  if (d->size > 32 * 1024 * 1024 || d->size < 0x92e700) {
    fclose(f);
    return 0;
  }
  rewind(f);
  d->data = malloc(d->size);
  if (!d->data) {
    fclose(f);
    return 0;
  }
  int ok = fread(d->data, 1, d->size, f) == d->size;
  fclose(f);
  if (!ok) {
    free(d->data);
    d->data = NULL;
    return 0;
  }
  unsigned char hash[CC_SHA256_DIGEST_LENGTH];
  char hex[65];
  CC_SHA256(d->data, (CC_LONG)d->size, hash);
  for (unsigned i = 0; i < 32; i++)
    snprintf(hex + i * 2, 3, "%02x", hash[i]);
  if (strcmp(hex, expected_hash)) {
    free(d->data);
    d->data = NULL;
    return 0;
  }
  return 1;
}
static uint32_t word(const uint8_t *b, unsigned off) {
  uint32_t w;
  memcpy(&w, b + off, 4);
  return w;
}
static void setword(uint8_t *b, unsigned off, uint32_t w) {
  memcpy(b + off, &w, 4);
}
static int stock_valid(const Disk *d, const Profile *p) {
  if ((size_t)p->slice + p->size > d->size)
    return 0;
  const uint8_t *b = d->data + p->slice + p->preamble;
  double a;
  memcpy(&a, d->data + p->slice + p->constant, 8);
  return a == .695 && word(b, 0) == word(b, 12) && word(b, 8) == 0x6f00e403 &&
         word(b, 72) == 0x1e732a73 && word(b, 136) == 0x1e713873;
}
// ADRP always uses a 4 KiB architectural page, even on a 16 KiB VM page system.
static int adrp_encode(uint64_t pc, uint64_t dest, uint32_t *out) {
  int64_t delta = (int64_t)(dest >> 12) - (int64_t)(pc >> 12);
  if (delta < -(1 << 20) || delta > ((1 << 20) - 1) || (dest & 4095))
    return 0;
  uint32_t u = (uint32_t)delta & 0x1fffff;
  *out = 0x9000000b | ((u & 3) << 29) | ((u >> 2) << 5);
  return 1;
}
static uint64_t adrp_decode(uint64_t pc, uint32_t w) {
  int64_t pages = ((w >> 29) & 3) | (((w >> 5) & 0x7ffff) << 2);
  if (pages & (1 << 20))
    pages -= 1 << 21;
  return (pc & ~UINT64_C(4095)) + pages * 4096;
}
static int plan(uint64_t code, uint64_t scratch,
                const uint8_t stock[BLOCK_SIZE], uint8_t out[BLOCK_SIZE]) {
  uint32_t adrp;
  if (!adrp_encode(code, scratch, &adrp))
    return 0;
  memcpy(out, stock, BLOCK_SIZE);
  setword(out, 0, adrp);
  setword(out, 4, 0xfd400162);
  setword(out, 8, 0xfd400563);
  setword(out, 72, 0x1e630a73);
  setword(out, 136, 0x1e614233);
  return 1;
}
static int restricted(void) {
  typedef int (*check_fn)(uint32_t);
  check_fn fn = (check_fn)dlsym(RTLD_DEFAULT, "csr_check");
  return !fn ||
         fn(1u << 2) != 0; // CSR_ALLOW_TASK_FOR_PID (debugging restrictions).
}
static pid_t dock_pid(struct proc_bsdinfo *result) {
  uid_t owner = getuid();
  if (owner == 0) {
    struct stat st;
    if (!stat("/dev/console", &st))
      owner = st.st_uid;
  }
  int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
  if (bytes <= 0)
    return 0;
  pid_t *p = calloc(1, (size_t)bytes);
  if (!p)
    return 0;
  int n = proc_listpids(PROC_ALL_PIDS, 0, p, bytes) / (int)sizeof(pid_t);
  pid_t found = 0;
  for (int i = 0; i < n; i++) {
    struct proc_bsdinfo b;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidinfo(p[i], PROC_PIDTBSDINFO, 0, &b, sizeof(b)) !=
            (int)sizeof(b) ||
        b.pbi_uid != owner)
      continue;
    if (proc_pidpath(p[i], path, sizeof(path)) > 0 && !strcmp(path, DOCK)) {
      if (found) {
        found = 0;
        break;
      }
      found = p[i];
      *result = b;
    }
  }
  free(p);
  return found;
}
static const Profile *profile_for_uuid(const uint8_t uuid[16]) {
  for (unsigned i = 0; i < sizeof(profiles) / sizeof(*profiles); i++)
    if (!memcmp(uuid, profiles[i].uuid, 16))
      return &profiles[i];
  return NULL;
}
static int image_profile(Target *t, Disk *d) {
  struct task_dyld_info info;
  mach_msg_type_number_t n = TASK_DYLD_INFO_COUNT;
  if (task_info(t->task, TASK_DYLD_INFO, (task_info_t)&info, &n) !=
      KERN_SUCCESS)
    return 0;
  struct dyld_all_image_infos images;
  if (!read_remote(t->task, info.all_image_info_addr, &images,
                   sizeof(images)) ||
      !images.infoArrayCount || !images.infoArray)
    return 0;
  struct dyld_image_info first;
  if (!read_remote(t->task, (uint64_t)images.infoArray, &first, sizeof(first)))
    return 0;
  t->base = (uint64_t)first.imageLoadAddress;
  uint8_t header[16384];
  if (!read_remote(t->task, t->base, header, sizeof(header)))
    return 0;
  struct mach_header_64 *h = (void *)header;
  if (h->magic != MH_MAGIC_64 || h->filetype != MH_EXECUTE ||
      h->sizeofcmds > sizeof(header) - sizeof(*h))
    return 0;
  size_t off = sizeof(*h);
  uint8_t *uuid = NULL;
  for (uint32_t i = 0; i < h->ncmds; i++) {
    if (off + 8 > sizeof(header))
      return 0;
    struct load_command *lc = (void *)(header + off);
    if (lc->cmdsize < 8 || off + lc->cmdsize > sizeof(header))
      return 0;
    if (lc->cmd == LC_UUID && lc->cmdsize == sizeof(struct uuid_command))
      uuid = ((struct uuid_command *)lc)->uuid;
    off += lc->cmdsize;
  }
  if (!uuid)
    return 0;
  t->profile = profile_for_uuid(uuid);
  if (!t->profile || !stock_valid(d, t->profile))
    return 0;
  t->code = t->base + t->profile->preamble;
  memcpy(t->stock, d->data + t->profile->slice + t->profile->preamble,
         BLOCK_SIZE);
  return read_remote(t->task, t->code, t->current, BLOCK_SIZE);
}
static int inspect(Target *t) {
  if (!memcmp(t->stock, t->current, BLOCK_SIZE)) {
    t->patched = 0;
    return 1;
  }
  uint32_t adrp = word(t->current, 0);
  if ((adrp & 0x9f00001f) != 0x9000000b)
    return 0;
  t->scratch = adrp_decode(t->code, adrp);
  uint8_t expected[BLOCK_SIZE];
  if (!plan(t->code, t->scratch, t->stock, expected) ||
      memcmp(expected, t->current, BLOCK_SIZE) ||
      !read_remote(t->task, t->scratch, &t->meta, sizeof(t->meta)))
    return 0;
  if (t->meta.magic != MAGIC || t->meta.code != t->code ||
      t->meta.pid != (uint64_t)t->pid ||
      t->meta.start_sec != t->proc.pbi_start_tvsec ||
      t->meta.start_usec != t->proc.pbi_start_tvusec ||
      memcmp(t->meta.uuid, t->profile->uuid, 16))
    return 0;
  double a, g;
  if (st_coefficients(t->meta.factor, 120, &a, &g) || a != t->meta.retention ||
      g != t->meta.gain || t->meta.factor == 1)
    return 0;
  t->patched = 1;
  return 1;
}
static int target_open(Target *t, Disk *d) {
  memset(t, 0, sizeof(*t));
  t->pid = dock_pid(&t->proc);
  if (!t->pid)
    return fail("No unique Dock for the console user.");
  kern_return_t kr = task_for_pid(mach_task_self(), t->pid, &t->task);
  if (kr != KERN_SUCCESS)
    return fail("Dock task access denied; root and SIP debugging exception are "
                "required.");
  if (!image_profile(t, d) || !inspect(t))
    return fail("Running Dock image or patch ownership is not recognized; no "
                "writes performed.");
  return 0;
}
static void target_close(Target *t) {
  if (t->task)
    mach_port_deallocate(mach_task_self(), t->task);
}
int st_check(const char *path) {
  Disk d;
  if (!disk_load(path ? path : DOCK, &d))
    return fail("Unsupported Dock SHA-256. This build supports only macOS "
                "27.0.1 (26A434).");
  int ok = 1;
  for (unsigned i = 0; i < 2; i++) {
    uint8_t patch[BLOCK_SIZE];
    ok &= stock_valid(&d, &profiles[i]) &&
          plan(UINT64_C(0x100000000) + profiles[i].preamble,
               UINT64_C(0x100800000),
               d.data + profiles[i].slice + profiles[i].preamble, patch);
  }
  free(d.data);
  if (!ok)
    return fail("Offline profile validation failed.");
  puts("{\"compatible\":true,\"message\":\"Both arm64e Dock profiles and patch "
       "plans verified offline.\"}");
  return 0;
}
int st_status(void) {
  Disk d;
  int compatible = disk_load(DOCK, &d), sip = restricted();
  Target t;
  memset(&t, 0, sizeof(t));
  int known = 0;
  if (compatible && !sip && geteuid() == 0 && !target_open(&t, &d))
    known = 1;
  printf("{\"compatible\":%s,\"patched\":%s,\"patchKnown\":%s,"
         "\"sipRestricted\":%s,\"duration\":%.17g,\"message\":\"%s\"}\n",
         compatible ? "true" : "false", known && t.patched ? "true" : "false",
         known ? "true" : "false", sip ? "true" : "false",
         known && t.patched ? t.meta.factor : 1.0,
         !compatible ? "Unsupported Dock build."
         : sip       ? "SIP debugging restrictions block Dock access."
         : !known    ? "Runtime state requires administrator access."
         : t.patched ? "SpaceTempo patch active."
                     : "Stock Spaces animation.");
  target_close(&t);
  if (compatible)
    free(d.data);
  return 0;
}
// The target must remain stopped throughout a write and any rollback.
static int flush(task_t task, mach_vm_address_t address, mach_vm_size_t size) {
  vm_machine_attribute_val_t value = MATTR_VAL_CACHE_FLUSH;
  return mach_vm_machine_attribute(task, address, size, MATTR_CACHE, &value) ==
         KERN_SUCCESS;
}
static int write_verify(Target *t, const uint8_t *bytes) {
  uint8_t actual[BLOCK_SIZE];
  return mach_vm_write(t->task, t->code, (vm_offset_t)bytes, BLOCK_SIZE) ==
             KERN_SUCCESS &&
         read_remote(t->task, t->code, actual, BLOCK_SIZE) &&
         !memcmp(actual, bytes, BLOCK_SIZE) &&
         flush(t->task, t->code, BLOCK_SIZE);
}
static int transaction(Target *t, const uint8_t next[BLOCK_SIZE], int *safe) {
  *safe = 1;
  mach_vm_address_t region = t->code;
  mach_vm_size_t size;
  vm_region_basic_info_data_64_t info;
  mach_msg_type_number_t n = VM_REGION_BASIC_INFO_COUNT_64;
  mach_port_t object = MACH_PORT_NULL;
  kern_return_t kr =
      mach_vm_region(t->task, &region, &size, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &n, &object);
  if (object)
    mach_port_deallocate(mach_task_self(), object);
  if (kr != KERN_SUCCESS || region > t->code ||
      t->code + BLOCK_SIZE > region + size)
    return fail("Cannot verify target code protection.");
  mach_vm_address_t page = t->code & ~((uint64_t)vm_page_size - 1);
  if (t->code + BLOCK_SIZE > page + vm_page_size)
    return fail("Patch crosses a VM page.");
  if (!(info.protection & VM_PROT_EXECUTE) ||
      !flush(t->task, t->code, BLOCK_SIZE))
    return fail("Target instruction-cache maintenance unavailable; no writes "
                "performed.");
  kr = mach_vm_protect(t->task, page, vm_page_size, FALSE,
                       VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
  if (kr != KERN_SUCCESS)
    return fail("Cannot make Dock code privately writable.");
  int wrote = write_verify(t, next);
  int restored = mach_vm_protect(t->task, page, vm_page_size, FALSE,
                                 info.protection) == KERN_SUCCESS;
  if (wrote && restored)
    return 0;
  // Retry the original snapshot under writable protection, then restore
  // protection.
  int writable = mach_vm_protect(t->task, page, vm_page_size, FALSE,
                                 VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) ==
                 KERN_SUCCESS;
  int rolled = writable && write_verify(t, t->current);
  restored = mach_vm_protect(t->task, page, vm_page_size, FALSE,
                             info.protection) == KERN_SUCCESS;
  if (!rolled || !restored) {
    *safe = 0;
    return fail("CRITICAL: rollback failed; Dock remains suspended. Restart "
                "Dock manually to recover.");
  }
  return fail(
      "Patch transaction failed; original code and protection restored.");
}
static int in_spring(Target *t, uint64_t pc) {
  // Remote saved LR can carry PAC; compare its canonical 48-bit address.
  pc &= UINT64_C(0x0000ffffffffffff);
  return pc >= t->code - 0xc0 && pc < t->code + 0x124;
}
static int frame_chain_clear(Target *t, const arm_thread_state64_t *state) {
  if (in_spring(t, arm_thread_state64_get_pc(*state)) ||
      in_spring(t, arm_thread_state64_get_lr(*state)))
    return 0;
  uint64_t fp = arm_thread_state64_get_fp(*state);
  for (unsigned depth = 0; fp && depth < 128; depth++) {
    if (fp & 15)
      return 0;
    uint64_t frame[2];
    if (!read_remote(t->task, fp, frame, sizeof(frame)))
      return 0;
    if (in_spring(t, frame[1]))
      return 0;
    if (!frame[0])
      return 1;
    if (frame[0] <= fp || frame[0] - fp > 64 * 1024 * 1024)
      return 0;
    fp = frame[0];
  }
  return fp == 0; // Refuse if unwinding cannot conclusively finish.
}
static int threads_clear(Target *t) {
  struct proc_bsdinfo now;
  if (proc_pidinfo(t->pid, PROC_PIDTBSDINFO, 0, &now, sizeof(now)) !=
          (int)sizeof(now) ||
      now.pbi_start_tvsec != t->proc.pbi_start_tvsec ||
      now.pbi_start_tvusec != t->proc.pbi_start_tvusec)
    return 0;
  thread_act_array_t threads = NULL;
  mach_msg_type_number_t count = 0;
  if (task_threads(t->task, &threads, &count) != KERN_SUCCESS)
    return 0;
  int clear = 1;
  for (unsigned i = 0; i < count; i++) {
    arm_thread_state64_t state;
    mach_msg_type_number_t n = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(threads[i], ARM_THREAD_STATE64, (thread_state_t)&state,
                         &n) != KERN_SUCCESS)
      clear = 0;
    else if (!frame_chain_clear(t, &state))
      clear = 0;
    mach_port_deallocate(mach_task_self(), threads[i]);
  }
  vm_deallocate(mach_task_self(), (vm_address_t)threads,
                count * sizeof(thread_t));
  return clear;
}
static int allocate_near(Target *t, mach_vm_address_t *out) {
  // Fixed address allocation avoids the allocator repeatedly returning an
  // out-of-range region.
  uint64_t center = t->code & ~((uint64_t)vm_page_size - 1);
  for (uint64_t distance = 0x100000; distance < UINT64_C(0x80000000);
       distance += 0x100000) {
    for (int sign = 1; sign >= -1; sign -= 2) {
      uint64_t candidate = sign > 0 ? center + distance : center - distance;
      if (sign < 0 && center < distance)
        continue;
      mach_vm_address_t a = candidate;
      uint32_t instruction;
      if (adrp_encode(t->code, a, &instruction) &&
          mach_vm_allocate(t->task, &a, vm_page_size, VM_FLAGS_FIXED) ==
              KERN_SUCCESS) {
        *out = a;
        return 1;
      }
    }
  }
  return 0;
}
static int change(double factor, int revert) {
  if (restricted())
    return fail(
        "SIP debugging restrictions enabled. No system setting was changed.");
  if (geteuid() != 0)
    return fail("Run apply/revert with administrator privileges.");
  Disk d;
  if (!disk_load(DOCK, &d))
    return fail("Unsupported Dock binary; refusing runtime changes.");
  // Root-owned lock serializes our writers; reject replaced or attacker-owned
  // lock files.
  int lock =
      open("/var/run/space-tempo.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
  struct stat st;
  if (lock < 0 || fstat(lock, &st) || st.st_uid != 0 || !S_ISREG(st.st_mode) ||
      st.st_nlink != 1 || (st.st_mode & 077) ||
      flock(lock, LOCK_EX | LOCK_NB)) {
    if (lock >= 0)
      close(lock);
    free(d.data);
    return fail("Cannot acquire secure SpaceTempo transaction lock.");
  }
  Target t;
  int rc = target_open(&t, &d);
  free(d.data);
  if (rc) {
    target_close(&t);
    close(lock);
    return rc;
  }
  if (revert && !t.patched) {
    puts("Stock Spaces animation already active.");
    target_close(&t);
    close(lock);
    return 0;
  }
  if (task_suspend(t.task) != KERN_SUCCESS) {
    target_close(&t);
    close(lock);
    return fail("Could not suspend Dock safely.");
  }
  int safe = 1;
  mach_vm_address_t fresh = 0;
  uint8_t next[BLOCK_SIZE];
  // Re-read after suspension; no decision based on a stale snapshot.
  if (!read_remote(t.task, t.code, t.current, BLOCK_SIZE) || !inspect(&t)) {
    rc = fail("Dock changed before transaction; refusing write.");
    goto done;
  }
  if (!threads_clear(&t)) {
    rc = fail("Dock is executing the Spaces spring or target identity changed; "
              "retry when the animation is idle.");
    goto done;
  }
  if (revert)
    memcpy(next, t.stock, BLOCK_SIZE);
  else {
    if (!allocate_near(&t, &fresh)) {
      rc = fail("No scratch page available within ADRP range.");
      goto done;
    }
    Scratch s = {0};
    if (st_coefficients(factor, 120, &s.retention, &s.gain)) {
      rc = fail("Invalid spring coefficients.");
      goto done;
    }
    s.magic = MAGIC;
    s.code = t.code;
    s.pid = t.pid;
    s.start_sec = t.proc.pbi_start_tvsec;
    s.start_usec = t.proc.pbi_start_tvusec;
    s.factor = factor;
    memcpy(s.uuid, t.profile->uuid, 16);
    if (mach_vm_write(t.task, fresh, (vm_offset_t)&s, sizeof(s)) !=
            KERN_SUCCESS ||
        mach_vm_protect(t.task, fresh, vm_page_size, FALSE, VM_PROT_READ) !=
            KERN_SUCCESS ||
        !plan(t.code, fresh, t.stock, next)) {
      rc = fail("Scratch setup failed.");
      goto done;
    }
  }
  rc = transaction(&t, next, &safe);
  if (!rc) {
    if (t.patched)
      mach_vm_deallocate(t.task, t.scratch, vm_page_size);
    fresh = 0;
    puts(
        revert
            ? "Original Spaces instructions restored."
            : "Spaces spring duration factor applied. Dock restart clears it.");
  }
done:
  // Do not release potentially referenced data following an unverifiable
  // rollback.
  if (fresh && safe)
    mach_vm_deallocate(t.task, fresh, vm_page_size);
  if (safe && task_resume(t.task) != KERN_SUCCESS)
    rc = fail("Dock resume failed; restart Dock manually.");
  target_close(&t);
  close(lock);
  return rc;
}
int st_apply(double multiplier) {
  if (!isfinite(multiplier) || multiplier < .25 || multiplier > 1)
    return fail("Duration factor must be in [0.25, 1].");
  return multiplier == 1 ? st_revert() : change(multiplier, 0);
}
int st_revert(void) { return change(1, 1); }
