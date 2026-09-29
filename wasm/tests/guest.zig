//! The module the integration tests load: one export per behaviour the binding promises.
extern "env" fn host_echo(ptr: [*]const u8, len: u32) i32;
extern "env" fn host_nested() i32;

export fn add(left: i32, right: i32) i32 {
    return left + right;
}

export fn echo() i32 {
    const text = "hello from the guest";

    return host_echo(text.ptr, text.len);
}

export fn nested() i32 {
    return host_nested() + 1;
}

export fn spin(rounds: u32) u32 {
    var total: u32 = 0;
    var index: u32 = 0;

    while (index < rounds) : (index += 1) {
        total +%= index *% 31;
        asm volatile ("");
    }

    return total;
}

export fn grow(pages: u32) i32 {
    return @intCast(@as(isize, @bitCast(@wasmMemoryGrow(0, pages))));
}

export fn crash() void {
    unreachable;
}
