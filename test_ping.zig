const std = @import("std");

fn ping() []const u8 {
    return "ok";
}

test "ping smoke test" {
    try std.testing.expectEqualStrings("ok", ping());
}
