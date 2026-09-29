//! Compiled by the unpacked toolchain in the tests: 128-bit arithmetic needs compiler_rt.
export fn multiply(left: u64, right: u64) u64 {
    const wide = @as(u128, left) * @as(u128, right);
    return @truncate(wide >> 32);
}
