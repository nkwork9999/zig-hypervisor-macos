// 独立した SDL2 viewer プロセス。
// stdin から framebuffer raw BGRA を受け取り window 描画、
// キーボードイベントを stdout に書き出す。
//
// zigvm は子プロセスとしてこれを起動し、stdin/stdout を pipe で繋ぐ。
//
// 使い方: zigvm-viewer WIDTH HEIGHT
const std = @import("std");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    const w_str = args.next() orelse "1024";
    const h_str = args.next() orelse "768";
    const width = try std.fmt.parseInt(c_int, w_str, 10);
    const height = try std.fmt.parseInt(c_int, h_str, 10);

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) return error.SdlInit;
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        "ZigVM Linux",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        width,
        height,
        c.SDL_WINDOW_SHOWN,
    ) orelse return error.SdlWindow;
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED) orelse return error.SdlRenderer;
    defer c.SDL_DestroyRenderer(renderer);

    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_ARGB8888,
        c.SDL_TEXTUREACCESS_STREAMING,
        width,
        height,
    ) orelse return error.SdlTexture;
    defer c.SDL_DestroyTexture(texture);

    c.SDL_StartTextInput();

    const fb_size = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    const stride: c_int = width * 4;
    const fb = try std.heap.page_allocator.alloc(u8, fb_size);
    defer std.heap.page_allocator.free(fb);
    @memset(fb, 0);

    // stdin を non-blocking
    const stdin_fd: std.posix.fd_t = 0;
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const O_NONBLOCK: u32 = 0x0004;
    const flags = std.c.fcntl(stdin_fd, F_GETFL, @as(i32, 0));
    _ = std.c.fcntl(stdin_fd, F_SETFL, flags | @as(i32, @intCast(O_NONBLOCK)));

    const stdout_fd: std.posix.fd_t = 1;

    var running = true;
    // フレーム境界を跨いで read_total を保持。完全に1フレーム揃うまで texture 更新しない (torn frame 防止)
    var fb_off: usize = 0;
    while (running) {
        while (fb_off < fb_size) {
            const n = std.posix.read(stdin_fd, fb[fb_off..]) catch |e| {
                if (e == error.WouldBlock) break;
                running = false;
                break;
            };
            if (n == 0) {
                running = false;
                break;
            }
            fb_off += n;
        }
        if (fb_off >= fb_size) {
            _ = c.SDL_UpdateTexture(texture, null, fb.ptr, stride);
            fb_off = 0;
        }

        // 2) SDL events
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev) != 0) {
            switch (ev.type) {
                c.SDL_QUIT => running = false,
                c.SDL_TEXTINPUT => {
                    var n: usize = 0;
                    var buf: [16]u8 = undefined;
                    for (ev.text.text) |ch| {
                        if (ch == 0) break;
                        if (ch < 0x80 and n < buf.len) {
                            buf[n] = @intCast(ch);
                            n += 1;
                        }
                    }
                    if (n > 0) _ = std.posix.write(stdout_fd, buf[0..n]) catch {};
                },
                c.SDL_KEYDOWN => {
                    const sym = ev.key.keysym.sym;
                    const mod = ev.key.keysym.mod;
                    const ctrl = (mod & (c.KMOD_LCTRL | c.KMOD_RCTRL)) != 0;
                    var buf: [4]u8 = undefined;
                    var n: usize = 0;
                    if (sym == c.SDLK_RETURN or sym == c.SDLK_KP_ENTER) {
                        buf[0] = '\r';
                        n = 1;
                    } else if (sym == c.SDLK_BACKSPACE) {
                        buf[0] = 0x7F;
                        n = 1;
                    } else if (sym == c.SDLK_TAB) {
                        buf[0] = '\t';
                        n = 1;
                    } else if (sym == c.SDLK_ESCAPE) {
                        buf[0] = 0x1B;
                        n = 1;
                    } else if (sym == c.SDLK_UP) {
                        buf = .{ 0x1B, '[', 'A', 0 };
                        n = 3;
                    } else if (sym == c.SDLK_DOWN) {
                        buf = .{ 0x1B, '[', 'B', 0 };
                        n = 3;
                    } else if (sym == c.SDLK_RIGHT) {
                        buf = .{ 0x1B, '[', 'C', 0 };
                        n = 3;
                    } else if (sym == c.SDLK_LEFT) {
                        buf = .{ 0x1B, '[', 'D', 0 };
                        n = 3;
                    } else if (ctrl and sym >= 'a' and sym <= 'z') {
                        buf[0] = @intCast((sym - 'a') + 1);
                        n = 1;
                    } else if (ctrl and sym >= 'A' and sym <= 'Z') {
                        buf[0] = @intCast((sym - 'A') + 1);
                        n = 1;
                    }
                    if (n > 0) _ = std.posix.write(stdout_fd, buf[0..n]) catch {};
                },
                else => {},
            }
        }

        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderCopy(renderer, texture, null, null);
        c.SDL_RenderPresent(renderer);

        c.SDL_Delay(16); // ~60fps
    }
}
