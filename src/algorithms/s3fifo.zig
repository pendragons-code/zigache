const std = @import("std");
const utils = @import("../utils/utils.zig");
const assert = std.debug.assert;

const Map = @import("../structures/map.zig").Map;
const DoublyLinkedList = @import("../structures/dbl.zig").DoublyLinkedList;
const Allocator = std.mem.Allocator;

/// S3FIFO is an advanced FIFO-based caching policy that uses three segments:
/// small, main, and ghost. It aims to combine the simplicity of FIFO with
/// improved performance for various access patterns. S3FIFO can adapt to both
/// recency and frequency of access, making it effective for a wide range of
/// workloads.
///
/// More information can be found here:
/// https://s3fifo.com/
pub fn S3FIFO(comptime K: type, comptime V: type) type {
    return struct {
        const Promotion = enum { SmallToMain, SmallToGhost, GhostToMain };
        const QueueType = enum { Small, Main, Ghost };
        const Node = @import("../structures/node.zig").Node(K, V, struct {
            // Indicates which queue (Small, Main, or Ghost) the node is currently in
            queue: QueueType,
            // Tracks the access frequency of the node, used for eviction decisions
            freq: u2,
        });

        map: Map(K, Node),
        small: DoublyLinkedList(Node) = .{},
        main: DoublyLinkedList(Node) = .{},
        ghost: DoublyLinkedList(Node) = .{},
        mutex: std.Thread.RwLock = .{},

        max_size: u32,
        main_size: usize,
        small_size: usize,
        ghost_size: usize,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, total_size: u32, base_size: u32) !Self {
            // Allocate 10% of total size to small queue, and split the rest between main and ghost
            const small_size = @max(1, total_size / 10);
            const other_size = @max(1, (total_size - small_size) / 2);

            return .{
                .map = try Map(K, Node).init(allocator, total_size, base_size),
                .max_size = small_size + other_size * 2,
                .main_size = other_size,
                .small_size = small_size,
                .ghost_size = other_size,
            };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit();
        }

        pub fn contains(self: *Self, key: K, hash_code: u64) bool {
            self.mutex.lockShared();
            defer self.mutex.unlockShared();

            return self.map.contains(key, hash_code);
        }

        pub fn count(self: *Self) usize {
            self.mutex.lockShared();
            defer self.mutex.unlockShared();

            return self.map.count();
        }

        pub fn get(self: *Self, key: K, hash_code: u64) ?V {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.map.get(key, hash_code)) |node| {
                if (self.map.checkTTL(node)) {
                    self.removeFromList(node);
                    return null;
                }

                // Increment frequency, capped at 3
                if (node.data.freq < 3) {
                    node.data.freq = @min(node.data.freq + 1, 3);
                }
                return node.value;
            }
            return null;
        }

        pub fn set(self: *Self, key: K, value: V, ttl: ?u64, hash_code: u64) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Ensure cache size doesn't exceed max_size
            while (self.small.len + self.main.len + self.ghost.len >= self.max_size) {
                self.evict();
            }

            const node, const found_existing = try self.map.set(key, hash_code);
            node.* = .{
                .key = key,
                .value = value,
                .next = if (found_existing) node.next else null,
                .prev = if (found_existing) node.prev else null,
                .expiry = utils.getExpiry(ttl),
                .data = .{
                    .queue = if (found_existing) node.data.queue else .Small,
                    .freq = if (found_existing) node.data.freq else 0,
                },
            };

            if (found_existing) {
                if (node.data.queue == .Ghost) {
                    // Move from Ghost to Main on re-insertion
                    node.data.queue = .Main;
                    self.ghost.remove(node);
                    self.main.append(node);
                }
            } else {
                // New items always start in Small queue
                self.small.append(node);
            }
        }

        pub fn remove(self: *Self, key: K, hash_code: u64) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            return if (self.map.remove(key, hash_code)) |node| {
                // Remove the node from the respective list as well
                self.removeFromList(node);
                self.map.pool.release(node);
                return true;
            } else false;
        }

        fn evict(self: *Self) void {
            // Prioritize evicting from Small queue if it's full
            if (self.small.len >= self.small_size) {
                self.evictSmall();
            } else {
                self.evictMain();
            }
        }

        fn evictMain(self: *Self) void {
            while (self.main.popFirst()) |node| {
                // We want to evict an item with a frequency of 0
                // If the item has a positive frequency, decrement it
                // and move to the end of Main queue
                if (node.data.freq > 0) {
                    node.data.freq -= 1;
                    self.main.append(node);
                } else {
                    assert(self.map.remove(node.key, null) != null);
                    self.map.pool.release(node);
                    break;
                }
            }
        }

        fn evictSmall(self: *Self) void {
            while (self.small.popFirst()) |node| {
                // If the item has been accessed more than once, move to Main queue.
                // Otherwise, move to Ghost queue.
                //
                // The S3FIFO paper suggests checking if freq > 1, but due to bad hitrate
                // in short to medium term tests, we're using freq > 0 instead.
                if (node.data.freq > 0) {
                    node.data.freq = 0;
                    node.data.queue = .Main;
                    self.main.append(node);
                } else {
                    if (self.ghost.len >= self.main_size) {
                        self.evictGhost();
                    }
                    node.data.queue = .Ghost;
                    self.ghost.append(node);
                    break;
                }
            }
        }

        fn evictGhost(self: *Self) void {
            if (self.ghost.popFirst()) |node| {
                // Remove oldest ghost entry when ghost queue is full
                assert(self.map.remove(node.key, null) != null);
                self.map.pool.release(node);
            }
        }

        fn removeFromList(self: *Self, node: *Node) void {
            switch (node.data.queue) {
                .Small => self.small.remove(node),
                .Main => self.main.remove(node),
                .Ghost => self.ghost.remove(node),
            }
        }
    };
}

const testing = std.testing;

fn initTestCache(total_size: u32) !utils.TestCache(S3FIFO(u32, []const u8)) {
    return try utils.TestCache(S3FIFO(u32, []const u8)).init(testing.allocator, total_size);
}

test "S3FIFO - basic insert and get" {
    var cache = try initTestCache(10);
    defer cache.deinit();

    try cache.set(1, "value1");
    try cache.set(2, "value2");

    try testing.expectEqualStrings("value1", cache.get(1).?);
    try testing.expectEqualStrings("value2", cache.get(2).?);
}

test "S3FIFO - overwrite existing key" {
    var cache = try initTestCache(10);
    defer cache.deinit();

    try cache.set(1, "value1");
    try cache.set(1, "new_value1");

    // Check that the value has been updated
    try testing.expectEqualStrings("new_value1", cache.get(1).?);
}

test "S3FIFO - remove key" {
    var cache = try initTestCache(5);
    defer cache.deinit();

    try cache.set(1, "value1");

    // Remove the key and check that it's no longer present
    try testing.expect(cache.remove(1));
    try testing.expect(cache.get(1) == null);

    // Ensure that a second remove is idempotent
    try testing.expect(!cache.remove(1));
}

test "S3FIFO - eviction and promotion" {
    var cache = try initTestCache(5); // Total size: 5 (small: 1, main: 2, ghost: 2)
    defer cache.deinit();

    // Fill the cache
    try cache.set(1, "value1");
    try cache.set(2, "value2");
    try cache.set(3, "value3");
    try cache.set(4, "value4");
    try cache.set(5, "value5");

    // Access increase the frequency of 1, 2, 3, 4
    _ = cache.get(1);
    _ = cache.get(2);
    _ = cache.get(3);
    _ = cache.get(4);

    // Insert a new key, which should evict key 1 (least frequently used )
    try cache.set(6, "value6"); // 6 moves to small, 5 is evicted to ghost, everything else moves to main

    // We expect key 5 to be in the ghost cache
    try testing.expect(cache.get(1) == null);
    try testing.expect(cache.get(2) != null);
    try testing.expect(cache.get(3) != null);
    try testing.expect(cache.get(4) != null);
    try testing.expect(cache.get(5) != null);
    try testing.expect(cache.get(6) != null);
}

test "S3FIFO - TTL functionality" {
    var cache = try initTestCache(5);
    defer cache.deinit();

    try cache.setTTL(1, "value1", 1); // 1ms TTL
    std.time.sleep(2 * std.time.ns_per_ms);
    try testing.expect(cache.get(1) == null);

    try cache.setTTL(2, "value2", 1000); // 1s TTL
    try testing.expect(cache.get(2) != null);
}
