pub const VT100 = struct {
    /// The VT100 'ESC'ape character.
    pub const ESC = [_]u8{27};
    pub const GO_TO = ESC ++ "[{d};{d}H";
    pub const BG = ESC ++ "[48;2;{d};{d};{d}m";
    pub const FG = ESC ++ "[38;2;{d};{d};{d}m";
    pub const GO_TOP_LEFT = ESC ++ "[1;1H";
    pub const CLEAR = ESC ++ "[0J";

    pub const UP = ESC ++ "[A";
    pub const DOWN = ESC ++ "[B";
    pub const RIGHT = ESC ++ "[C";
    pub const LEFT = ESC ++ "[D";
    pub const UP_N = ESC ++ "[{d}A";
    pub const DOWN_N = ESC ++ "[{d}B";
    pub const RIGHT_N = ESC ++ "[{d}C";
    pub const LEFT_N = ESC ++ "[{d}D";
    pub const CURSOR_HIDE = ESC ++ "[?25l";
    pub const CURSOR_SHOW = ESC ++ "[?25h";

    pub const FGBlack = ESC ++ "[30m";
    pub const FGRed = ESC ++ "[31m";
    pub const FGGreen = ESC ++ "[32m";
    pub const FGYellow = ESC ++ "[33m";
    pub const FGBlue = ESC ++ "[34m";
    pub const FGMagenta = ESC ++ "[35m";
    pub const FGCyan = ESC ++ "[36m";
    pub const FGLightGray = ESC ++ "[37m";
    pub const FGDarkGray = ESC ++ "[90m";
    pub const FGLightGreen = ESC ++ "[92m";
    pub const FGLightYellow = ESC ++ "[93m";
    pub const FGLightBlue = ESC ++ "[94m";
    pub const FGLightMagenta = ESC ++ "[95m";
    pub const FGLightCyan = ESC ++ "[96m";
    pub const FGWhite = ESC ++ "[97m";

    pub const BGBlack = ESC ++ "[40m";
    pub const BGRed = ESC ++ "[41m";
    pub const BGGreen = ESC ++ "[42m";
    pub const BGYellow = ESC ++ "[4m";
    pub const BGBlue = ESC ++ "[44m";
    pub const BGMagenta = ESC ++ "[45m";
    pub const BGCyan = ESC ++ "[46m";
    pub const BGLightGray = ESC ++ "[47m";
    pub const BGDarkGray = ESC ++ "[100m";
    pub const BGLightGreen = ESC ++ "[102m";
    pub const BGLightYellow = ESC ++ "[103m";
    pub const BGLightBlue = ESC ++ "[104m";
    pub const BGLightMagenta = ESC ++ "[105m";
    pub const BGLightCyan = ESC ++ "[106m";
    pub const BGWhite = ESC ++ "[107m";
};

/// Terminal size dimensions
pub const TermSize = struct {
    /// Terminal width as measured number of characters that fit into a terminal horizontally
    width: u16,
    /// terminal height as measured number of characters that fit into terminal vertically
    height: u16,
};

/// Get terminal size
pub fn getSize(file: std.fs.File) !TermSize {
    if (!file.supportsAnsiEscapeCodes()) {
        return error.NO_ANSI;
    }
    return switch (builtin.os.tag) {
        .linux, .macos => blk: {
            var buf: posix.winsize = undefined;
            break :blk switch (posix.errno(
                posix.system.ioctl(
                    file.handle,
                    posix.T.IOCGWINSZ,
                    @intFromPtr(&buf),
                ),
            )) {
                .SUCCESS => TermSize{
                    .width = buf.col,
                    .height = buf.row,
                },
                else => error.IoctlError,
            };
        },
        else => error.Unsupported,
    };
}

var ORIGINAL: posix.termios = undefined;
pub fn rawOn() !void {
    // Flags from
    // https://www.man7.org/linux/man-pages/man3/termios.3.html Raw Mode
    // Descriptions from
    // https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html#disable-ctrl-s-and-ctrl-q
    switch (builtin.os.tag) {
        .linux, .macos => {
            // Get terminal attributes and save the original ones.
            var attr = try posix.tcgetattr(posix.STDIN_FILENO);
            ORIGINAL = attr;

            attr.iflag.IGNBRK = false;
            attr.iflag.BRKINT = false;
            attr.iflag.PARMRK = false;
            attr.iflag.ISTRIP = false;
            attr.iflag.INLCR = false;
            attr.iflag.IGNCR = false;
            // Fix Ctrl + M
            attr.iflag.ICRNL = false;
            // disable ctrl + s and ctrl + q
            // Cs stops sending bytes till Cq
            attr.iflag.IXON = false;
            // Disable output processing
            // when enabled \n is translated as \r\n. Turning that off
            attr.oflag.OPOST = false;
            // print typed to stdout
            attr.lflag.ECHO = false;
            attr.lflag.ECHONL = false;
            // unbuffered instead of line buffered
            attr.lflag.ICANON = false;
            // Disable ctrl + c and ctrl + z
            attr.lflag.ISIG = false;
            // Disable Ctrl + v
            // Cv sends the next typed char literally instead of as an action
            attr.lflag.IEXTEN = false;
            attr.cflag.PARENB = false;
            attr.cflag.CSIZE = .CS8;

            try posix.tcsetattr(posix.STDIN_FILENO, .NOW, attr);
        },
        else => error.Unsupported,
    }
}

pub fn rawOff() !void {
    return posix.tcsetattr(posix.STDIN_FILENO, .NOW, ORIGINAL);
}

/// Global flag indicating wether the WINCH posix signal was recieved,
/// indicating that the host terminal changed size.
pub var NEEDS_RESIZE = false;
pub fn listenForResize() !void {
    const act: posix.Sigaction = .{
        .handler = .{ .sigaction = handleSigWinch },
        .mask = posix.empty_sigset,
        .flags = (posix.SA.SIGINFO | posix.SA.RESTART),
    };
    posix.sigaction(posix.SIG.WINCH, &act, null);
}

fn handleSigWinch(sig: i32, info: *const posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
    _ = info;
    _ = ctx_ptr;
    std.debug.assert(sig == posix.SIG.WINCH);
    NEEDS_RESIZE = true;
}

test "enter and exit raw mode" {
    try rawOn();
    try rawOff();
}

test "termSize" {
    std.debug.print("termsize {any}", .{getSize(std.io.getStdOut())});
}

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const io = std.io;
const os = std.os;
