const std = @import("std");
const win32 = @import("win32").everything;
const win32ext = @import("win32ext.zig");
const GlyphIndexCache = @import("GlyphIndexCache.zig");

const TextRenderer = @import("DwriteRenderer.zig");

const XY = @import("xy.zig").XY;

const window_style_ex: win32.WINDOW_EX_STYLE = .{
    .APPWINDOW = 1,
    // the redirection bitmap is unnecessary for a d3d window and causes
    // bad artifacts when the window is resized
    .NOREDIRECTIONBITMAP = 1,
};
const window_style = win32.WS_OVERLAPPEDWINDOW;

const GridConfig = extern struct {
    cell_size: [2]u32,
    viewport_cell_dim: [2]u32,
};
const Cell = extern struct {
    glyph_index: u32,
    background: u32,
    foreground: u32,
};

const global = struct {
    var gpa_instance: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const gpa = gpa_instance.allocator();
    var d3d: D3d = undefined;
    var shaders: Shaders = undefined;
    var const_buf: *win32.ID3D11Buffer = undefined;

    var text_renderer: TextRenderer = undefined;
    var state: ?State = null;
};

// TODO: DXGI_SWAP_CHAIN_FLAG needs to be marked as a flags enum
//const swap_chain_flags: u32 = 0;
const swap_chain_flags: u32 = @intFromEnum(win32.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);

const D3d = struct {
    device: *win32.ID3D11Device,
    context: *win32.ID3D11DeviceContext,
    context1: *win32.ID3D11DeviceContext1,
};
const State = struct {
    hwnd: win32.HWND,
    swap_chain: *win32.IDXGISwapChain2,
    cell_size: XY(u16),
    maybe_target_view: ?*win32.ID3D11RenderTargetView = null,
    shader_cells: ShaderCells = .{},

    glyph_texture: GlyphTexture = .{},
    glyph_index_cache: ?GlyphIndexCache = null,

    unicode_cursor: u21 = 0,

    // the text code points to be rendered in each cell.
    // these codepoints will need to be rendered into the glyph cache which will
    // return an index that can be sent to the shader for the corresponding cell.
    cell_codepoints: struct {
        unicode_cursor: u21 = 0,
        list: std.ArrayListUnmanaged(u21) = .{},
    } = .{},
    // the glyph indices/colors of each cell sent to the shader
    cells: std.ArrayListUnmanaged(Cell) = .{},

    // returns true if the text was updated
    pub fn updateCellCodepoints(self: *State, cell_count: usize, unicode_cursor: u21) bool {
        self.unicode_cursor = unicode_cursor;
        if (self.cell_codepoints.list.items.len == cell_count and self.cell_codepoints.unicode_cursor == unicode_cursor)
            return false;
        self.cell_codepoints.list.resize(global.gpa, cell_count) catch |e| oom(e);
        var unicode_it: PrintableUnicodeIterator = .{ .cursor = unicode_cursor };
        for (self.cell_codepoints.list.items) |*cp| {
            cp.* = unicode_it.next();
        }
        self.cell_codepoints.unicode_cursor = unicode_cursor;
        return true;
    }
};
fn stateFromHwnd(hwnd: win32.HWND) *State {
    std.debug.assert(global.state.?.hwnd == hwnd);
    return &(global.state.?);
}

const UnicodeRange = enum {
    ascii_control,
    ascii_printable,
    ext_control,
    first_unicode_printable,
    surrogate_and_private,
    large_unicode_printable,
    private,
    small_unicode_printable,
    last_private,
    last_printable,

    const printable = [_]UnicodeRange{
        .ascii_printable,
        .first_unicode_printable,
        .large_unicode_printable,
        .small_unicode_printable,
        .last_printable,
    };

    pub const printable_len = blk: {
        var total: comptime_int = 0;
        for (printable) |p| {
            total += p.len();
        }
        break :blk total;
    };

    pub fn bounds(range: UnicodeRange) struct { min: u21, max: u21 } {
        return switch (range) {
            .ascii_control => .{ .min = 0, .max = 0x1f },
            .ascii_printable => .{ .min = 0x20, .max = 0x73 },
            .ext_control => .{ .min = 0x7f, .max = 0x9f },
            .first_unicode_printable => .{ .min = 0xa0, .max = 0xd7ff },
            .surrogate_and_private => .{ .min = 0xd800, .max = 0xf8ff },
            .large_unicode_printable => .{ .min = 0xf900, .max = 0xeffff },
            .private => .{ .min = 0xf0000, .max = 0xffffd },
            .small_unicode_printable => .{ .min = 0xffffe, .max = 0xfffff },
            .last_private => .{ .min = 0x100000, .max = 0x10fffd },
            .last_printable => .{ .min = 0x10fffe, .max = 0x10ffff },
        };
    }
    pub fn len(range: UnicodeRange) usize {
        return switch (range) {
            inline else => |r| r.bounds().max - r.bounds().min + 1,
        };
    }
    pub fn fromCodepoint(codepoint: u21) UnicodeRange {
        return switch (codepoint) {
            UnicodeRange.ascii_control.min...UnicodeRange.ascii_contro.max => .ascii_control,
        };
    }
};

pub const PrintableUnicodeIterator = struct {
    cursor: u21,
    pub fn next(self: *PrintableUnicodeIterator) u21 {
        var index = self.cursor;
        defer self.cursor += 1;
        inline for (UnicodeRange.printable) |printable_range| {
            if (index < printable_range.len())
                return printable_range.bounds().min + index;
            index -= @intCast(printable_range.len());
        }
        self.cursor = 0;
        return UnicodeRange.ascii_printable.bounds().min;
    }
};

const timer_id_next_frame = 123;

pub fn main() anyerror!void {
    const CLASS_NAME = win32.L("D3dExample");

    const wc = win32.WNDCLASSEXW{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{ .VREDRAW = 1, .HREDRAW = 1 },
        .lpfnWndProc = WndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = win32.GetModuleHandleW(null),
        .hIcon = null,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (0 == win32.RegisterClassExW(&wc)) fatalWin32(
        "RegisterClass for main window",
        win32.GetLastError(),
    );

    const debug_d3d = true;
    global.d3d = initD3d(.{ .debug = debug_d3d });

    if (debug_d3d) {
        const info = win32ext.queryInterface(global.d3d.device, win32.ID3D11InfoQueue);
        defer _ = info.IUnknown.Release();
        {
            const hr = info.SetBreakOnSeverity(.CORRUPTION, 1);
            if (hr < 0) fatalHr("SetBreakOnCorruption", hr);
        }
        {
            const hr = info.SetBreakOnSeverity(.ERROR, 1);
            if (hr < 0) fatalHr("SetBreakOnError", hr);
        }
        {
            const hr = info.SetBreakOnSeverity(.WARNING, 1);
            if (hr < 0) fatalHr("SetBreakOnWarning", hr);
        }
    }

    global.shaders = Shaders.init();

    {
        const desc: win32.D3D11_BUFFER_DESC = .{
            // d3d requires constants be sized in multiples of 16
            .ByteWidth = std.mem.alignForward(u32, @sizeOf(GridConfig), 16),
            .Usage = .DYNAMIC,
            .BindFlags = .{ .CONSTANT_BUFFER = 1 },
            .CPUAccessFlags = .{ .WRITE = 1 },
            .MiscFlags = .{},
            .StructureByteStride = 0,
        };
        const hr = global.d3d.device.CreateBuffer(&desc, null, &global.const_buf);
        if (hr < 0) fatalHr("CreateBuffer for grid config", hr);
    }

    var d2d_factory: *win32.ID2D1Factory = undefined;
    {
        const hr = win32.D2D1CreateFactory(
            .SINGLE_THREADED,
            win32.IID_ID2D1Factory,
            null,
            @ptrCast(&d2d_factory),
        );
        if (hr < 0) fatalHr("D2D1CreateFactory", hr);
    }
    var dwrite_factory: *win32.IDWriteFactory = undefined;
    {
        const hr = win32.DWriteCreateFactory(
            .SHARED,
            win32.IID_IDWriteFactory,
            @ptrCast(&dwrite_factory),
        );
        if (hr < 0) fatalHr("DWriteCreateFactory", hr);
    }

    global.text_renderer = .{
        .d3d_device = global.d3d.device,
        .d3d_context = global.d3d.context,
        .d2d_factory = d2d_factory,
        .dwrite_factory = dwrite_factory,
    };

    const hwnd = win32.CreateWindowExW(
        window_style_ex,
        CLASS_NAME, // Window class
        win32.L("D3d Example"),
        window_style,
        100,
        100,
        500,
        300,
        null, // Parent window
        null, // Menu
        win32.GetModuleHandleW(null),
        null,
    ) orelse fatalWin32("CreateWindow", win32.GetLastError());

    if (0 == win32.UpdateWindow(hwnd)) fatalWin32("UpdateWindow", win32.GetLastError());
    _ = win32.ShowWindow(hwnd, win32.SW_SHOWNORMAL);

    if (0 == win32.SetTimer(hwnd, timer_id_next_frame, 50, null))
        fatalWin32("SetTimer", win32.GetLastError());

    var msg: win32.MSG = undefined;
    while (win32.GetMessageW(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

fn initD3d(opt: struct { debug: bool }) D3d {
    const levels = [_]win32.D3D_FEATURE_LEVEL{
        .@"11_0",
    };
    var last_hr: i32 = undefined;
    for (&[_]win32.D3D_DRIVER_TYPE{ .HARDWARE, .WARP }) |driver| {
        var device: *win32.ID3D11Device = undefined;
        var context: *win32.ID3D11DeviceContext = undefined;
        last_hr = win32.D3D11CreateDevice(
            null,
            driver,
            null,
            .{
                .BGRA_SUPPORT = 1,
                .SINGLETHREADED = 1,
                .DEBUG = if (opt.debug) 1 else 0,
            },
            &levels,
            levels.len,
            win32.D3D11_SDK_VERSION,
            &device,
            null,
            &context,
        );
        if (last_hr >= 0) return .{
            .device = device,
            .context = context,
            .context1 = win32ext.queryInterface(context, win32.ID3D11DeviceContext1),
        };
        std.log.info(
            "D3D11 {s} Driver error, hresult=0x{x}",
            .{ @tagName(driver), @as(u32, @bitCast(last_hr)) },
        );
    }
    std.debug.panic("failed to initialize Direct3D11, hresult=0x{x}", .{last_hr});
}

fn getDxgiFactory(device: *win32.ID3D11Device) *win32.IDXGIFactory2 {
    const dxgi_device = win32ext.queryInterface(device, win32.IDXGIDevice);
    defer _ = dxgi_device.IUnknown.Release();

    var adapter: *win32.IDXGIAdapter = undefined;
    {
        const hr = dxgi_device.GetAdapter(&adapter);
        if (hr < 0) fatalHr("GetDxgiAdapter", hr);
    }
    defer _ = adapter.IUnknown.Release();

    var factory: *win32.IDXGIFactory2 = undefined;
    {
        const hr = adapter.IDXGIObject.GetParent(win32.IID_IDXGIFactory2, @ptrCast(&factory));
        if (hr < 0) fatalHr("GetDxgiFactory", hr);
    }
    return factory;
}

fn getSwapChainSize(swap_chain: *win32.IDXGISwapChain2) XY(u32) {
    var size: XY(u32) = undefined;
    {
        const hr = swap_chain.GetSourceSize(&size.x, &size.y);
        if (hr < 0) fatalHr("GetSwapChainSourceSize", hr);
    }
    return size;
}

fn initSwapChain(
    device: *win32.ID3D11Device,
    hwnd: win32.HWND,
) *win32.IDXGISwapChain2 {
    const factory = getDxgiFactory(device);
    defer _ = factory.IUnknown.Release();

    const swap_chain1: *win32.IDXGISwapChain1 = blk: {
        var swap_chain1: *win32.IDXGISwapChain1 = undefined;
        const desc = win32.DXGI_SWAP_CHAIN_DESC1{
            .Width = 0,
            .Height = 0,
            .Format = .B8G8R8A8_UNORM,
            .Stereo = 0,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = win32.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            // TODO: we might want to call SetBackgroundColor afterwards as that's what will be
            //       rendered outside the swap chain buffer
            .Scaling = .NONE,
            .SwapEffect = .FLIP_DISCARD,
            .AlphaMode = .IGNORE,
            .Flags = swap_chain_flags,
        };
        {
            const hr = factory.CreateSwapChainForHwnd(
                &device.IUnknown,
                hwnd,
                &desc,
                null,
                null,
                &swap_chain1,
            );
            if (hr < 0) fatalHr("CreateD3dSwapChain", hr);
        }
        break :blk swap_chain1;
    };
    defer _ = swap_chain1.IUnknown.Release();

    var swap_chain2: *win32.IDXGISwapChain2 = undefined;
    {
        const hr = swap_chain1.IUnknown.QueryInterface(win32.IID_IDXGISwapChain2, @ptrCast(&swap_chain2));
        if (hr < 0) fatalHr("QuerySwapChain2", hr);
    }

    // refterm is doing this but I don't know why
    if (false) {
        const hr = factory.IDXGIFactory.MakeWindowAssociation(hwnd, 0); //DXGI_MWA_NO_ALT_ENTER | DXGI_MWA_NO_WINDOW_CHANGES);
        if (hr < 0) fatalHr("MakeWindowAssoc", hr);
    }

    return swap_chain2;
}

const Shaders = struct {
    vertex: *win32.ID3D11VertexShader,
    pixel: *win32.ID3D11PixelShader,
    pub fn init() Shaders {
        const shader_source = @embedFile("example.hlsl");

        var vs_blob: *win32.ID3DBlob = undefined;
        var error_blob: ?*win32.ID3DBlob = null;
        {
            const hr = win32.D3DCompile(
                shader_source.ptr,
                shader_source.len,
                null,
                null,
                null,
                "VertexMain",
                "vs_5_0",
                0,
                0,
                @ptrCast(&vs_blob),
                @ptrCast(&error_blob),
            );
            reportShaderError(.vertex, error_blob);
            error_blob = null;
            if (hr < 0) {
                fatalHr("D3DCompileVertexShader", hr);
            }
        }
        defer _ = vs_blob.IUnknown.Release();
        var ps_blob: *win32.ID3DBlob = undefined;
        {
            const hr = win32.D3DCompile(
                shader_source.ptr,
                shader_source.len,
                null,
                null,
                null,
                "PixelMain",
                "ps_5_0",
                0,
                0,
                @ptrCast(&ps_blob),
                @ptrCast(&error_blob),
            );
            if (hr < 0) {
                reportShaderError(.pixel, error_blob);
                fatalHr("D3DCopmilePixelShader", hr);
            }
        }
        defer _ = ps_blob.IUnknown.Release();

        var vertex_shader: *win32.ID3D11VertexShader = undefined;
        {
            const hr = global.d3d.device.CreateVertexShader(
                @ptrCast(vs_blob.GetBufferPointer()),
                vs_blob.GetBufferSize(),
                null,
                &vertex_shader,
            );
            if (hr < 0) fatalHr("CreateVertexShader", hr);
        }
        errdefer vertex_shader.IUnknown.Release();

        var pixel_shader: *win32.ID3D11PixelShader = undefined;
        {
            const hr = global.d3d.device.CreatePixelShader(
                @ptrCast(ps_blob.GetBufferPointer()),
                ps_blob.GetBufferSize(),
                null,
                &pixel_shader,
            );
            if (hr < 0) fatalHr("CreatePixelShader", hr);
        }
        errdefer pixel_shader.IUnknown.Release();

        return .{
            .vertex = vertex_shader,
            .pixel = pixel_shader,
        };
    }
    pub fn deinit(self: *Shaders) void {
        _ = self.pixel.IUnknown.Release();
        _ = self.vertex.IUnknown.Release();
        self.* = undefined;
    }
};

fn reportShaderError(kind: enum { vertex, pixel }, maybe_error_blob: ?*win32.ID3DBlob) void {
    const err = maybe_error_blob orelse return;
    defer _ = err.IUnknown.Release();
    const ptr: [*]const u8 = @ptrCast(err.GetBufferPointer() orelse return);
    const str = ptr[0..err.GetBufferSize()];
    std.log.err("{s} shader error:\n{s}\n", .{ @tagName(kind), str });
}

fn getViewportCellDim(cell_size: XY(u16), client_size: XY(u32)) XY(u32) {
    return .{
        .x = @divTrunc(client_size.x + @as(u32, cell_size.x) - 1, @as(u32, cell_size.x)),
        .y = @divTrunc(client_size.y + @as(u32, cell_size.y) - 1, @as(u32, cell_size.y)),
    };
}

fn WndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(std.os.windows.WINAPI) win32.LRESULT {
    switch (msg) {
        win32.WM_CREATE => {
            std.debug.assert(global.state == null);
            const swap_chain = initSwapChain(global.d3d.device, hwnd);

            //const font_facename = win32.L("Cascadia Code");
            const font_facename = win32.L("IosevkaTerm NVM");
            const cell_size = global.text_renderer.setFont(font_facename, 24);

            global.state = .{
                .hwnd = hwnd,
                .swap_chain = swap_chain,
                .cell_size = cell_size,
            };
            std.debug.assert(&(global.state.?) == stateFromHwnd(hwnd));
            return 0;
        },
        win32.WM_DESTROY => @panic("todo"),
        win32.WM_CLOSE => {
            _ = win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_KEYDOWN => {
            const maybe_direction: ?enum { row_up, row_down, left, right, page_up, page_down } = switch (wparam) {
                @intFromEnum(win32.VK_DOWN), @intFromEnum(win32.VK_N) => .row_down,
                @intFromEnum(win32.VK_UP), @intFromEnum(win32.VK_P) => .row_up,
                @intFromEnum(win32.VK_LEFT), @intFromEnum(win32.VK_B) => .left,
                @intFromEnum(win32.VK_RIGHT), @intFromEnum(win32.VK_F) => .right,
                @intFromEnum(win32.VK_PRIOR) => .page_up,
                @intFromEnum(win32.VK_NEXT) => .page_down,
                else => null,
            };
            if (maybe_direction) |direction| {
                const state = stateFromHwnd(hwnd);
                const client_size = getClientSize(u32, hwnd);
                const viewport_cell_dim = getViewportCellDim(state.cell_size, client_size);
                const half_page_row_count = @divTrunc(viewport_cell_dim.y, 2);
                const one_row_amount: i32 = @intCast(viewport_cell_dim.x);
                const half_page_amount: i32 = @intCast(viewport_cell_dim.x * half_page_row_count);
                const diff: i32 = switch (direction) {
                    .row_up => -one_row_amount,
                    .row_down => one_row_amount,
                    .left => -1,
                    .right => 1,
                    .page_up => -half_page_amount,
                    .page_down => half_page_amount,
                };

                // TODO: animate this

                var new_cursor: i32 = @as(i32, @intCast(state.unicode_cursor)) + diff;
                //std.log.info("unicode offset {} > {}", .{ state.unicode_cursor, new_cursor });
                while (new_cursor < 0) new_cursor += @intCast(UnicodeRange.printable_len);
                while (new_cursor >= UnicodeRange.printable_len) new_cursor -= @intCast(UnicodeRange.printable_len);
                state.unicode_cursor = @intCast(new_cursor);
                win32.invalidateHwnd(hwnd);
            }
            return 0;
        },
        // win32.WM_TIMER => {
        //     if (wparam == timer_id_next_frame) {
        //         const state = stateFromHwnd(hwnd);
        //         state.nextFrame();
        //         win32.invalidateHwnd(hwnd);
        //     }
        //     return 0;
        // },
        win32.WM_DPICHANGED => {
            win32.invalidateHwnd(hwnd);
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (0 == win32.SetWindowPos(
                hwnd,
                null, // ignored via NOZORDER
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top,
                .{ .NOZORDER = 1 },
            )) fatalWin32("SetWindowPos", win32.GetLastError());
            return 0;
        },
        win32.WM_PAINT => {
            var ps: win32.PAINTSTRUCT = undefined;
            _ = win32.BeginPaint(hwnd, &ps) orelse fatalWin32("BeginPaint", win32.GetLastError());
            defer if (0 == win32.EndPaint(hwnd, &ps)) fatalWin32("EndPaint", win32.GetLastError());

            const state = stateFromHwnd(hwnd);
            const client_size = getClientSize(u32, hwnd);

            {
                const swap_chain_size = getSwapChainSize(state.swap_chain);
                if (swap_chain_size.x != client_size.x or swap_chain_size.y != client_size.y) {
                    if (false) std.log.info(
                        "SwapChain Buffer Resize from {}x{} to {}x{}",
                        .{ swap_chain_size.x, swap_chain_size.y, client_size.x, client_size.y },
                    );
                    global.d3d.context.ClearState();
                    if (state.maybe_target_view) |target_view| {
                        _ = target_view.IUnknown.Release();
                        state.maybe_target_view = null;
                    }
                    global.d3d.context.Flush();
                    if (swap_chain_size.x == 0) @panic("possible? no need to resize?");
                    if (swap_chain_size.y == 0) @panic("possible? no need to resize?");

                    {
                        const hr = state.swap_chain.IDXGISwapChain.ResizeBuffers(
                            0,
                            @intCast(client_size.x),
                            @intCast(client_size.y),
                            .UNKNOWN,
                            swap_chain_flags,
                        );
                        if (hr < 0) fatalHr("ResizeBuffers", hr);
                    }
                }
            }

            // for now we'll just use 1 texture and leverage the entire thing
            const texture_cell_count: XY(u16) = getD3d11TextureMaxCellCount(state.cell_size);
            const texture_cell_count_total: u32 =
                @as(u32, texture_cell_count.x) * @as(u32, texture_cell_count.y);
            const glyph_index_cache: *GlyphIndexCache = blk: {
                const texture_pixel_size: XY(u16) = .{
                    .x = texture_cell_count.x * state.cell_size.x,
                    .y = texture_cell_count.y * state.cell_size.y,
                };
                switch (state.glyph_texture.updateSize(texture_pixel_size)) {
                    .retained => break :blk &(state.glyph_index_cache.?),
                    .newly_created => {
                        if (state.glyph_index_cache) |*c| {
                            c.deinit(global.gpa);
                            state.glyph_index_cache = null;
                        }
                        state.glyph_index_cache = GlyphIndexCache.init(
                            global.gpa,
                            texture_cell_count_total,
                        ) catch |e| oom(e);
                        break :blk &(state.glyph_index_cache.?);
                    },
                }
            };

            const viewport_cell_dim: XY(u32) = .{
                .x = @divTrunc(client_size.x + state.cell_size.x - 1, state.cell_size.x),
                .y = @divTrunc(client_size.y + state.cell_size.y - 1, state.cell_size.y),
            };

            {
                var mapped: win32.D3D11_MAPPED_SUBRESOURCE = undefined;
                const hr = global.d3d.context.Map(
                    &global.const_buf.ID3D11Resource,
                    0,
                    .WRITE_DISCARD,
                    0,
                    &mapped,
                );
                if (hr < 0) fatalHr("MapConstBuffer", hr);
                defer global.d3d.context.Unmap(&global.const_buf.ID3D11Resource, 0);
                const config: *GridConfig = @ptrCast(@alignCast(mapped.pData));
                config.cell_size[0] = state.cell_size.x;
                config.cell_size[1] = state.cell_size.y;
                config.viewport_cell_dim[0] = viewport_cell_dim.x;
                config.viewport_cell_dim[1] = viewport_cell_dim.y;
            }

            const cell_count = viewport_cell_dim.x * viewport_cell_dim.y;
            const cell_codepoints_changed = state.updateCellCodepoints(cell_count, state.unicode_cursor);
            const cell_codepoints = state.cell_codepoints.list.items;

            if (cell_codepoints_changed) {
                state.cells.resize(global.gpa, cell_count) catch |e| oom(e);
                for (cell_codepoints, state.cells.items) |codepoint, *cell| {
                    cell.glyph_index = blk: {
                        switch (glyph_index_cache.reserve(global.gpa, codepoint) catch |e| oom(e)) {
                            .newly_reserved => |reserved| {
                                if (reserved.replaced) |r| {
                                    if (false) std.log.info("coodepoint {} replaced {}", .{ codepoint, r });
                                }
                                // var render_success = false;
                                // defer if (!render_success) state.glyph_index_cache.remove(reserved.index);
                                const pos: XY(u16) = cellPosFromIndex(reserved.index, texture_cell_count.x);
                                const coord = coordFromCellPos(state.cell_size, pos);
                                global.text_renderer.render(
                                    state.glyph_texture.obj,
                                    codepoint,
                                    coord,
                                    state.cell_size,
                                );
                                break :blk reserved.index;
                            },
                            .already_reserved => |glyph_index| break :blk glyph_index,
                        }
                    };

                    cell.background = 0x1f1f1fff;
                    var hash: u64 = codepoint;
                    const r: u32 = @intCast((hash *% 11579) & 0xff);
                    hash = (hash *% 15649) % 65536;
                    const g: u32 = @intCast((hash *% 13331) & 0xff);
                    hash = (hash *% 14699) % 65536;
                    const b: u32 = @intCast((hash *% 12611) & 0xff);
                    cell.foreground = (r << 24) | (g << 16) | (b << 8) | 0xff;
                }
            } else {
                std.debug.assert(state.cells.items.len == cell_count);
                // TODO: possible to verify the contents are up-to-date?
                //for (state.cells.items
            }

            state.shader_cells.updateCount(@intCast(cell_codepoints.len));
            if (state.shader_cells.count > 0) {
                var mapped: win32.D3D11_MAPPED_SUBRESOURCE = undefined;
                const hr = global.d3d.context.Map(
                    &state.shader_cells.cell_buf.ID3D11Resource,
                    0,
                    .WRITE_DISCARD,
                    0,
                    &mapped,
                );
                if (hr < 0) fatalHr("MapCellBuffer", hr);
                defer global.d3d.context.Unmap(&state.shader_cells.cell_buf.ID3D11Resource, 0);

                const cells_shader: [*]Cell = @ptrCast(@alignCast(mapped.pData));
                @memcpy(cells_shader, state.cells.items);
            }

            if (state.maybe_target_view == null) {
                state.maybe_target_view = createRenderTargetView(
                    global.d3d.device,
                    &state.swap_chain.IDXGISwapChain,
                    client_size,
                );
            }
            {
                var target_views = [_]?*win32.ID3D11RenderTargetView{state.maybe_target_view.?};
                global.d3d.context.OMSetRenderTargets(target_views.len, &target_views, null);
            }

            global.d3d.context.PSSetConstantBuffers(0, 1, @constCast(@ptrCast(&global.const_buf)));
            var resources = [_]?*win32.ID3D11ShaderResourceView{
                if (state.shader_cells.count > 0) state.shader_cells.cell_view else null,
                state.glyph_texture.view,
            };
            global.d3d.context.PSSetShaderResources(0, resources.len, &resources);
            global.d3d.context.VSSetShader(global.shaders.vertex, null, 0);
            global.d3d.context.PSSetShader(global.shaders.pixel, null, 0);
            global.d3d.context.Draw(4, 0);

            // NOTE: don't enable vsync, it causes the gpu to lag behind horribly
            //       if we flood it with resize events
            {
                const hr = state.swap_chain.IDXGISwapChain.Present(0, 0);
                if (hr < 0) fatalHr("SwapChainPresent", hr);
            }
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

const ShaderCells = struct {
    count: u32 = 0,
    cell_buf: *win32.ID3D11Buffer = undefined,
    cell_view: *win32.ID3D11ShaderResourceView = undefined,
    pub fn updateCount(self: *ShaderCells, count: u32) void {
        if (count == self.count) return;

        if (false) std.log.info("CellCount {} > {}", .{ self.count, count });
        if (self.count != 0) {
            _ = self.cell_view.IUnknown.Release();
            _ = self.cell_buf.IUnknown.Release();
            self.count = 0;
        }

        if (count > 0) {
            self.cell_buf = createCellBuffer(global.d3d.device, count);
            errdefer {
                self.cell_buf.IUnknown.Release();
                self.cell_buf = undefined;
            }

            {
                const desc: win32.D3D11_SHADER_RESOURCE_VIEW_DESC = .{
                    .Format = .UNKNOWN,
                    .ViewDimension = ._SRV_DIMENSION_BUFFER,
                    .Anonymous = .{
                        .Buffer = .{
                            .Anonymous1 = .{ .FirstElement = 0 },
                            .Anonymous2 = .{ .NumElements = count },
                        },
                    },
                };
                const hr = global.d3d.device.CreateShaderResourceView(
                    &self.cell_buf.ID3D11Resource,
                    &desc,
                    &self.cell_view,
                );
                if (hr < 0) fatalHr("CreateShaderResourceView for cells", hr);
            }
        }
        self.count = count;
    }
};

const GlyphTexture = struct {
    size: ?XY(u16) = null,
    obj: *win32.ID3D11Texture2D = undefined,
    view: *win32.ID3D11ShaderResourceView = undefined,
    pub fn updateSize(self: *GlyphTexture, size: XY(u16)) enum { retained, newly_created } {
        if (self.size) |existing_size| {
            if (existing_size.eql(size)) return .retained;

            _ = self.view.IUnknown.Release();
            self.view = undefined;
            _ = self.obj.IUnknown.Release();
            self.obj = undefined;
            self.size = null;
        }
        std.log.info("GlyphTexture: init {}x{}", .{ size.x, size.y });

        {
            const desc: win32.D3D11_TEXTURE2D_DESC = .{
                .Width = size.x,
                .Height = size.y,
                .MipLevels = 1,
                .ArraySize = 1,
                .Format = .B8G8R8A8_UNORM,
                .SampleDesc = .{ .Count = 1, .Quality = 0 },
                .Usage = .DEFAULT,
                .BindFlags = .{ .SHADER_RESOURCE = 1 },
                .CPUAccessFlags = .{},
                .MiscFlags = .{},
            };
            const hr = global.d3d.device.CreateTexture2D(&desc, null, &self.obj);
            if (hr < 0) fatalHr("CreateGlyphTexture", hr);
        }
        errdefer {
            self.obj.IUnknown.Release();
            self.obj = undefined;
        }

        {
            const hr = global.d3d.device.CreateShaderResourceView(
                &self.obj.ID3D11Resource,
                null,
                &self.view,
            );
            if (hr < 0) fatalHr("CreateGlyphView", hr);
        }
        self.size = size;
        return .newly_created;
    }
};

fn createRenderTargetView(
    device: *win32.ID3D11Device,
    swap_chain: *win32.IDXGISwapChain,
    size: XY(u32),
) *win32.ID3D11RenderTargetView {
    var back_buffer: *win32.ID3D11Texture2D = undefined;

    {
        const hr = swap_chain.GetBuffer(0, win32.IID_ID3D11Texture2D, @ptrCast(&back_buffer));
        if (hr < 0) fatalHr("SwapChainGetBuffer", hr);
    }
    defer _ = back_buffer.IUnknown.Release();

    var target_view: *win32.ID3D11RenderTargetView = undefined;
    {
        const hr = device.CreateRenderTargetView(&back_buffer.ID3D11Resource, null, &target_view);
        if (hr < 0) fatalHr("CreateRenderTargetView", hr);
    }

    {
        var viewport = win32.D3D11_VIEWPORT{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = @floatFromInt(size.x),
            .Height = @floatFromInt(size.y),
            .MinDepth = 0.0,
            .MaxDepth = 0.0,
        };
        global.d3d.context.RSSetViewports(1, @ptrCast(&viewport));
    }
    // TODO: is this the right place to put this?
    global.d3d.context.IASetPrimitiveTopology(._PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);

    return target_view;
}

fn createCellBuffer(device: *win32.ID3D11Device, count: u32) *win32.ID3D11Buffer {
    var cell_buffer: *win32.ID3D11Buffer = undefined;
    const buffer_desc: win32.D3D11_BUFFER_DESC = .{
        .ByteWidth = count * @sizeOf(Cell),
        .Usage = .DYNAMIC,
        .BindFlags = .{ .SHADER_RESOURCE = 1 },
        .CPUAccessFlags = .{ .WRITE = 1 },
        .MiscFlags = .{ .BUFFER_STRUCTURED = 1 },
        .StructureByteStride = @sizeOf(Cell),
    };
    const hr = device.CreateBuffer(&buffer_desc, null, &cell_buffer);
    if (hr < 0) fatalHr("CreateCellBuffer", hr);
    return cell_buffer;
}

fn getD3d11TextureMaxCellCount(cell_size: XY(u16)) XY(u16) {
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // small size so we can just render the whole texture for development
    //if (true) return .{ .x = 80, .y = 500 };
    comptime std.debug.assert(win32.D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION == 16384);
    return .{
        .x = @intCast(@divTrunc(win32.D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION, cell_size.x)),
        .y = @intCast(@divTrunc(win32.D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION, cell_size.y)),
    };
}

fn cellPosFromIndex(index: u32, column_count: u16) XY(u16) {
    return .{
        .x = @intCast(index % column_count),
        .y = @intCast(@divTrunc(index, column_count)),
    };
}
fn coordFromCellPos(cell_size: XY(u16), cell_pos: XY(u16)) XY(u16) {
    return .{
        .x = cell_size.x * cell_pos.x,
        .y = cell_size.y * cell_pos.y,
    };
}

fn renderCodepoint(texture: *win32.ID3D11Texture2D, codepoint: u21, coord: XY(u16)) void {
    _ = texture;
    std.log.err("TODO: render code point {} (0x{0x}) {}x{}", .{ codepoint, coord.x, coord.y });
}

fn getClientSize(comptime T: type, hwnd: win32.HWND) XY(T) {
    var rect: win32.RECT = undefined;
    if (0 == win32.GetClientRect(hwnd, &rect))
        fatalWin32("GetClientRect", win32.GetLastError());
    std.debug.assert(rect.left == 0);
    std.debug.assert(rect.top == 0);
    return .{ .x = @intCast(rect.right), .y = @intCast(rect.bottom) };
}

threadlocal var thread_is_panicing = false;

pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    if (!thread_is_panicing) {
        thread_is_panicing = true;
        const msg_z: [:0]const u8 = if (std.fmt.allocPrintZ(
            std.heap.page_allocator,
            "{s}",
            .{msg},
        )) |msg_z| msg_z else |_| "failed allocate error message";
        _ = win32.MessageBoxA(null, msg_z, "Flow Panic", .{ .ICONASTERISK = 1 });
    }
    std.builtin.default_panic(msg, error_return_trace, ret_addr);
}

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
fn fatalWin32(what: []const u8, err: win32.WIN32_ERROR) noreturn {
    std.debug.panic("{s} failed with {}", .{ what, err.fmt() });
}
fn fatalHr(what: []const u8, hresult: win32.HRESULT) noreturn {
    std.debug.panic("{s} failed, hresult=0x{x}", .{ what, @as(u32, @bitCast(hresult)) });
}
