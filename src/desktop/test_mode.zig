// Keep this guard at the start of each test named "desktop: ...".
pub fn requireDesktop() error{SkipZigTest}!void {
    if (@import("app_test_options").mode == .headless) return error.SkipZigTest;
}
