const std = @import("std");

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

pub const total_ms = 8000;
pub const reply_reserve_ms = 750;

/// Both processes use the Windows uptime clock, including time spent in transit.
pub fn now() u64 {
    return GetTickCount64();
}

pub fn remaining(deadline: u64, current: u64) u64 {
    return deadline -| current;
}

pub fn check(deadline: u64) error{ResolveDeadlineExceeded}!void {
    if (remaining(deadline, now()) == 0) return error.ResolveDeadlineExceeded;
}

test "resolution shares one budget across startup, worker work and reply" {
    const started = 100;
    const hard_deadline = started + total_ms;
    const work_deadline = hard_deadline - reply_reserve_ms;
    try std.testing.expectEqual(@as(u64, 4250), remaining(work_deadline, started + 3000));
    try std.testing.expectEqual(@as(u64, 1), remaining(work_deadline, work_deadline - 1));
    try std.testing.expectEqual(@as(u64, 0), remaining(work_deadline, work_deadline));
    try std.testing.expectEqual(@as(u64, reply_reserve_ms), remaining(hard_deadline, work_deadline));
    try std.testing.expectEqual(@as(u64, 0), remaining(hard_deadline, hard_deadline + 1));
}
