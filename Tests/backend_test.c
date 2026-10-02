// Offline tests; never acquire a task port or mutate Dock.
#include "../Sources/SpaceTempoCLI/backend.c"
#include <assert.h>
int main(void) {
  uint32_t instruction;
  uint64_t pc = UINT64_C(0x180001234);
  const int64_t deltas[] = {-(1 << 20), -1, 0, 1, (1 << 20) - 1};
  for (unsigned i = 0; i < sizeof(deltas) / sizeof(*deltas); i++) {
    uint64_t dest = (pc & ~UINT64_C(4095)) + deltas[i] * 4096;
    assert(adrp_encode(pc, dest, &instruction));
    assert(adrp_decode(pc, instruction) == dest);
  }
  assert(!adrp_encode(pc, (pc & ~UINT64_C(4095)) + UINT64_C(0x100000000),
                      &instruction));
  assert(!adrp_encode(pc, pc, &instruction));
  Disk d;
  assert(disk_load(DOCK, &d));
  for (unsigned i = 0; i < 2; i++) {
    assert(stock_valid(&d, &profiles[i]));
    const uint8_t *stock = d.data + profiles[i].slice + profiles[i].preamble;
    uint8_t patch[BLOCK_SIZE];
    uint64_t code = UINT64_C(0x100000000) + profiles[i].preamble,
             scratch = UINT64_C(0x100800000);
    assert(plan(code, scratch, stock, patch));
    assert(adrp_decode(code, word(patch, 0)) == scratch);
    assert(word(patch, 4) == 0xfd400162 && word(patch, 8) == 0xfd400563);
    assert(word(patch, 72) == 0x1e630a73 && word(patch, 136) == 0x1e614233);
    for (unsigned j = 0; j < BLOCK_SIZE; j++)
      if (!(j < 12 || (j >= 72 && j < 76) || (j >= 136 && j < 140)))
        assert(patch[j] == stock[j]);
  }
  uint8_t invalid_uuid[16] = {0};
  assert(!profile_for_uuid(invalid_uuid));
  for (unsigned i = 0; i < 2; i++)
    assert(profile_for_uuid(profiles[i].uuid) == &profiles[i]);
  assert(!disk_load("/dev/null", &(Disk){0}));
  char fixture[] = "/tmp/space-tempo-profile-XXXXXX";
  int fd = mkstemp(fixture);
  assert(fd >= 0);
  d.data[0] ^= 1;
  size_t written = 0;
  while (written < d.size) {
    ssize_t n = write(fd, d.data + written, d.size - written);
    assert(n > 0);
    written += (size_t)n;
  }
  Disk rejected;
  assert(!disk_load(fixture, &rejected));
  assert(ftruncate(fd, 128) == 0);
  assert(!disk_load(fixture, &rejected));
  close(fd);
  assert(unlink(fixture) == 0);
  free(d.data);
  puts("Backend ADRP boundaries and both offline patch profiles passed.");
  return 0;
}
