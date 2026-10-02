/* Integration test against an unused page in THIS process only.
 * Never calls target_open, task_for_pid, st_apply, or any Dock entry point.
 * The page has no executing thread, so self-suspension is neither needed
 * nor possible. This checks Mach write/cache/protection behavior, not Dock
 * compatibility, privileges, or suspension of another process.
 */
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <assert.h>

static int fail_first_write;
static unsigned write_calls;

static kern_return_t test_mach_vm_write(vm_map_t task, mach_vm_address_t address,
                                       vm_offset_t data, mach_msg_type_number_t size)
{
    ++write_calls;
    if (fail_first_write) {
        fail_first_write = 0;
        /* Deliberately change half the bytes before reporting failure. The
         * rollback must restore real damage, rather than an untouched page.
         */
        kern_return_t result = mach_vm_write(task, address, data, size / 2);
        assert(result == KERN_SUCCESS);
        return KERN_FAILURE;
    }
    return mach_vm_write(task, address, data, size);
}

/* Intercept only the implementation under test; SDK declarations above and
 * direct fixture writes below use the real kernel call.
 */
#define mach_vm_write test_mach_vm_write
#include "../Sources/SpaceTempoCLI/backend.c"
#undef mach_vm_write

static vm_prot_t protection_at(mach_vm_address_t address)
{
    mach_vm_address_t region = address;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    const kern_return_t result = mach_vm_region(mach_task_self(), &region, &size,
        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
    if (object) mach_port_deallocate(mach_task_self(), object);
    assert(result == KERN_SUCCESS);
    assert(region <= address && address < region + size);
    return info.protection;
}

int main(void)
{
    const task_t self = mach_task_self();
    mach_vm_address_t page = 0;
    assert(mach_vm_allocate(self, &page, vm_page_size, VM_FLAGS_ANYWHERE) == KERN_SUCCESS);

    Target target = {0};
    target.task = self;
    target.code = page + 128;
    uint8_t next[BLOCK_SIZE];
    uint8_t observed[BLOCK_SIZE];
    for (unsigned i = 0; i < BLOCK_SIZE; ++i) {
        target.current[i] = (uint8_t)(i * 7u);
        next[i] = (uint8_t)(target.current[i] ^ 0xa5u);
    }
    memcpy(target.stock, target.current, BLOCK_SIZE);
    assert(mach_vm_write(self, target.code, (vm_offset_t)target.current,
                         BLOCK_SIZE) == KERN_SUCCESS);
    const vm_prot_t original = VM_PROT_READ | VM_PROT_EXECUTE;
    assert(mach_vm_protect(self, page, vm_page_size, FALSE, original) == KERN_SUCCESS);
    assert(protection_at(target.code) == original);

    /* A refusal is a failing integration test, never permission to bypass
     * cache maintenance. Report the actual kernel result for diagnosis.
     */
    vm_machine_attribute_val_t value = MATTR_VAL_CACHE_FLUSH;
    kern_return_t cache_result = mach_vm_machine_attribute(self, target.code,
        BLOCK_SIZE, MATTR_CACHE, &value);
    if (cache_result != KERN_SUCCESS) {
        fprintf(stderr, "Instruction-cache maintenance unsupported on self task: %s (%d). "
                        "Transaction safety gate must remain enabled.\n",
                mach_error_string(cache_result), cache_result);
        assert(mach_vm_deallocate(self, page, vm_page_size) == KERN_SUCCESS);
        return 1;
    }

    int safe = 0;
    assert(transaction(&target, next, &safe) == 0);
    assert(safe == 1);
    assert(read_remote(self, target.code, observed, sizeof observed));
    assert(memcmp(observed, next, sizeof observed) == 0);
    assert(protection_at(target.code) == original);

    memcpy(target.current, next, BLOCK_SIZE);
    assert(transaction(&target, target.stock, &safe) == 0);
    assert(safe == 1);
    assert(read_remote(self, target.code, observed, sizeof observed));
    assert(memcmp(observed, target.stock, sizeof observed) == 0);
    assert(protection_at(target.code) == original);

    memcpy(target.current, target.stock, BLOCK_SIZE);
    write_calls = 0;
    fail_first_write = 1;
    assert(transaction(&target, next, &safe) != 0);
    assert(safe == 1 && fail_first_write == 0 && write_calls == 2);
    assert(read_remote(self, target.code, observed, sizeof observed));
    assert(memcmp(observed, target.stock, sizeof observed) == 0);
    assert(protection_at(target.code) == original);

    /* A non-executable page must be refused before any write attempt. */
    assert(mach_vm_protect(self, page, vm_page_size, FALSE, VM_PROT_READ) == KERN_SUCCESS);
    write_calls = 0;
    assert(transaction(&target, next, &safe) != 0);
    assert(safe == 1 && write_calls == 0);
    assert(read_remote(self, target.code, observed, sizeof observed));
    assert(memcmp(observed, target.stock, sizeof observed) == 0);
    assert(protection_at(target.code) == VM_PROT_READ);

    assert(mach_vm_deallocate(self, page, vm_page_size) == KERN_SUCCESS);
    puts("Self-task Mach apply/revert and partial-write rollback restored bytes and RX; "
         "non-executable page refused without writes.");
    return 0;
}
