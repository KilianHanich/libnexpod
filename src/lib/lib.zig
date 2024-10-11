const std = @import("std");
const utils = @import("utils");
const list = @import("list.zig");
const create = @import("create.zig");
const image = @import("image.zig");
const container = @import("container.zig");
pub const errors = @import("errors.zig");
const log = @import("logging");

pub const Image = image.Image;
pub const Name = image.Name;
pub const Container = container.Container;
pub const ContainerConfig = container.ContainerConfig;
pub const IdMapping = container.IdMapping;
pub const Mount = container.Mount;
pub const State = container.State;

/// a management handle to libnexpod related stuff
pub const LibnexpodStorage = struct {
    allocator: std.mem.Allocator,
    key: []const u8,

    /// creates a list of all available libnexpod images on disk in minimal form
    pub fn getImages(self: LibnexpodStorage) errors.ListErrors!std.ArrayList(image.Image) {
        return try list.listImages(self.allocator);
    }

    test getImages {
        const nps = try openLibnexpodStorage(std.testing.allocator, "libnexpod-unittest");
        defer nps.deinit();

        var image_list = try nps.getImages();
        defer {
            for (image_list.items) |e| {
                e.deinit();
            }
            image_list.deinit();
        }
        for (image_list.items) |*img| {
            try img.makeFull();
        }
    }

    /// creates a list of all currently existing libnexpod containers with the current key in minimal form
    pub fn getContainers(self: LibnexpodStorage) errors.ListErrors!std.ArrayList(container.Container) {
        return try list.listContainers(self.allocator, self.key);
    }

    test getContainers {
        const nps = try openLibnexpodStorage(std.testing.allocator, "");
        defer nps.deinit();

        var container_list = try nps.getContainers();
        defer {
            for (container_list.items) |e| {
                e.deinit();
            }
            container_list.deinit();
        }
        for (container_list.items) |*con| {
            try con.makeFull();
        }
    }

    /// creates a container based on passed in information and gives you back info to the container in full form
    /// you can pass in additional mounts via the `additional_mounts` options if you need to
    /// it uses the current process environment if you don't pass one in manually
    /// it uses the home directory of the current user if you don't specify one manually
    /// it uses the default path /usr/libexec/libnexpod/libnexpodd for libnexpodd_path
    /// all paths must be absolute paths
    /// the ownership of all parameters stays with the caller
    pub fn createContainer(self: LibnexpodStorage, args: struct {
        name: []const u8,
        env: ?std.process.EnvMap = null,
        additional_mounts: []const Mount = &[_]Mount{},
        home: ?[]const u8 = null,
        image: Image,
        libnexpodd_path: ?[]const u8 = null,
    }) errors.CreationErrors!container.Container {
        return try create.createContainer(self.allocator, .{
            .key = self.key,
            .name = args.name,
            .image = args.image,
            .env = args.env,
            .additional_mounts = args.additional_mounts,
            .home_dir = args.home,
            .libnexpodd_path = args.libnexpodd_path,
        });
    }

    /// returns necessary resources of ONLY this object storage
    /// you are expected to deinitialize all resources gained from this object (directly or indirectly) before you do this
    pub fn deinit(self: LibnexpodStorage) void {
        self.allocator.free(self.key);
    }
};

/// checks if podman is callable and then initializes a LibnexpodStorage object
/// the ownership of the parameters stays with the caller, but the storage object is not allowed to outlive the allocator
pub fn openLibnexpodStorage(allocator: std.mem.Allocator, key: []const u8) errors.InitStorageErrors!LibnexpodStorage {
    // check if podman exists
    const check_version_argv = [_][]const u8{ "podman", "version" };
    var child = std.process.Child.init(&check_version_argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| switch (err) {
        // Windows-Only
        error.InvalidName,
        error.InvalidHandle,
        error.WaitAbandoned,
        error.WaitTimeOut,
        error.CurrentWorkingDirectoryUnlinked,
        error.InvalidBatchScriptArg,
        error.InvalidWtf8,
        // WASI-Only
        error.InvalidUtf8,
        => unreachable,
        // we go via env variables, not paths
        error.NoDevice, error.IsDir, error.NotDir, error.BadPathName => unreachable,
        error.OutOfMemory, error.SystemResources, error.AccessDenied, error.InvalidExe, error.FileBusy, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.ResourceLimitReached, error.InvalidUserId, error.FileSystem, error.SymLinkLoop, error.NameTooLong, error.Unexpected => |rest| return rest,
        // Podman not found
        error.PermissionDenied, error.FileNotFound => return errors.PodmanErrors.PodmanNotFound,
    };
    {
        const version = try child.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(version);
        std.log.debug("podman version: {s}", .{version});
    }
    const result = child.wait() catch |err| switch (err) {
        // Windows-Only
        error.InvalidName,
        error.InvalidHandle,
        error.WaitAbandoned,
        error.WaitTimeOut,
        error.CurrentWorkingDirectoryUnlinked,
        error.InvalidBatchScriptArg,
        error.InvalidWtf8,
        // WASI-Only
        error.InvalidUtf8,
        => unreachable,
        // we go via env variables, not paths
        error.OutOfMemory, error.NoDevice, error.IsDir, error.NotDir, error.BadPathName => unreachable,
        error.SystemResources, error.AccessDenied, error.InvalidExe, error.FileBusy, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.ResourceLimitReached, error.InvalidUserId, error.FileSystem, error.SymLinkLoop, error.NameTooLong, error.Unexpected => |rest| return rest,
        // Podman not found
        error.PermissionDenied, error.FileNotFound => return errors.PodmanErrors.PodmanNotFound,
    };
    switch (result) {
        .Exited => |code| {
            switch (code) {
                0 => {},
                else => {
                    log.err("podman failed at getting its version information with exit code {}\n", .{code});
                    return errors.PodmanErrors.PodmanFailed;
                },
            }
        },
        else => |code| {
            log.err("podman failed unexpectedly while getting its version information with code {}\n", .{code});
            return errors.PodmanErrors.PodmanUnexpectedExit;
        },
    }
    const key_copy = try allocator.dupe(u8, key);
    errdefer allocator.free(key_copy);
    return .{
        .allocator = allocator,
        .key = key_copy,
    };
}

test openLibnexpodStorage {
    var nps = try openLibnexpodStorage(std.testing.allocator, "test");
    nps.deinit();
}
