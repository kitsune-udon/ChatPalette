const std = @import("std");

const sdk = @cImport({
    @cInclude("windows.h");
    @cInclude("mmdeviceapi.h");
    @cInclude("endpointvolume.h");
});

fn guid(a: u32, b: u16, c: u16, d: [8]u8) sdk.GUID {
    return .{ .Data1 = a, .Data2 = b, .Data3 = c, .Data4 = d };
}

const enumerator_class = guid(0xbcde0395, 0xe52f, 0x467c, .{ 0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e });
const enumerator_iid = guid(0xa95664d2, 0x9614, 0x4f35, .{ 0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6 });
const volume_iid = guid(0x5cdf2c82, 0x841e, 0x4546, .{ 0x97, 0x22, 0x0c, 0xf7, 0x40, 0x78, 0x22, 0x9a });

pub fn muteGuest() !u32 {
    // Read the actual Windows account. The environment can be set by any caller.
    const guest_user = std.unicode.utf8ToUtf16LeStringLiteral("WDAGUtilityAccount");
    var user: [256 + 1]u16 = undefined;
    var len: sdk.DWORD = user.len;
    if (sdk.GetUserNameW(&user, &len) == 0 or len != guest_user.len + 1 or
        !std.mem.eql(u16, user[0..guest_user.len], guest_user)) return error.SandboxAudioGuestRequired;

    if (sdk.CoInitializeEx(null, sdk.COINIT_MULTITHREADED) < 0) return error.SandboxAudioComUnavailable;
    defer sdk.CoUninitialize();

    var enumerator_raw: ?*anyopaque = null;
    if (sdk.CoCreateInstance(&enumerator_class, null, sdk.CLSCTX_INPROC_SERVER, &enumerator_iid, &enumerator_raw) < 0)
        return error.SandboxAudioEnumeratorUnavailable;
    const enumerator: *sdk.IMMDeviceEnumerator = @ptrCast(@alignCast(enumerator_raw orelse return error.SandboxAudioEnumeratorUnavailable));
    defer _ = enumerator.lpVtbl.*.Release.?(enumerator);

    var list: [*c]sdk.IMMDeviceCollection = null;
    if (enumerator.lpVtbl.*.EnumAudioEndpoints.?(enumerator, sdk.eRender, sdk.DEVICE_STATE_ACTIVE, &list) < 0 or list == null)
        return error.SandboxAudioOutputsUnavailable;
    defer _ = list.*.lpVtbl.*.Release.?(list);

    var count: u32 = 0;
    if (list.*.lpVtbl.*.GetCount.?(list, &count) < 0 or count == 0) return error.SandboxAudioOutputsUnavailable;
    for (0..count) |index| {
        var device: [*c]sdk.IMMDevice = null;
        if (list.*.lpVtbl.*.Item.?(list, @intCast(index), &device) < 0 or device == null)
            return error.SandboxAudioOutputUnavailable;
        defer _ = device.*.lpVtbl.*.Release.?(device);

        var volume_raw: ?*anyopaque = null;
        if (device.*.lpVtbl.*.Activate.?(device, &volume_iid, sdk.CLSCTX_INPROC_SERVER, null, &volume_raw) < 0)
            return error.SandboxAudioVolumeUnavailable;
        const volume: *sdk.IAudioEndpointVolume = @ptrCast(@alignCast(volume_raw orelse return error.SandboxAudioVolumeUnavailable));
        defer _ = volume.lpVtbl.*.Release.?(volume);
        var muted: sdk.BOOL = 0;
        if (volume.lpVtbl.*.SetMute.?(volume, 1, null) < 0 or
            volume.lpVtbl.*.GetMute.?(volume, &muted) < 0 or muted == 0) return error.SandboxAudioMuteUnverified;
    }
    return count;
}
