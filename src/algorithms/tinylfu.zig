const std = @import("std");
const zigache = @import("../zigache.zig");
const utils = zigache.utils;
const assert = std.debug.assert;

const CountMinSketch = zigache.CountMinSketch;
const Allocator = std.mem.Allocator;

/// W-TinyLFU is a hybrid cache eviction policy that combines a small window
/// cache with a larger main cache. It uses a frequency sketch to estimate item
/// popularity efficiently. This policy aims to capture both short-term and
/// long-term access patterns, providing high hit ratios across various workloads.
///
/// More information can be found here:
/// https://arxiv.org/pdf/1512.00727
pub fn TinyLFU(comptime K: type, comptime V: type, comptime thread_safety: bool) type {
    return struct {
        const CacheRegion = enum { Window, Probationary, Protected };

        const Data = struct {
            // Indicates which part of the cache this node belongs to:
            // Window: Recent entries, not yet in main cache
            // Probationary: Less frequently accessed items in main cache
            // Protected: Frequently accessed items in main cache
            region: CacheRegion,
        };

        const Node = zigache.Node(K, V, Data);
        const Map = zigache.Map(K, V, Data);
        const DoublyLinkedList = zigache.DoublyLinkedList(K, V, Data);
        const Mutex = if (thread_safety) std.Thread.RwLock else void;

        map: Map,
        window: DoublyLinkedList = .{},
        probationary: DoublyLinkedList = .{},
        protected: DoublyLinkedList = .{},
        mutex: Mutex = if (thread_safety) .{} else {},

        sketch: CountMinSketch,

        window_size: usize,
        probationary_size: usize,
        protected_size: usize,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, cache_size: u32, pool_size: u32) !Self {
            const window_size = @max(1, cache_size * 1 / 100); // 1% window cache
            const main_size = cache_size - window_size;
            const protected_size = @max(1, main_size * 8 / 10); // 80% of main cache
            const probationary_size = @max(1, main_size - protected_size); // 20% of main cache

            return .{
                .map = try Map.init(allocator, cache_size, pool_size),
                .sketch = try CountMinSketch.init(allocator, cache_size, 4),
                .window_size = window_size,
                .probationary_size = probationary_size,
                .protected_size = protected_size,
            };
        }

        pub fn deinit(self: *Self) void {
            self.sketch.deinit();
            self.window.clear();
            self.probationary.clear();
            self.protected.clear();
            self.map.deinit();
        }

        pub fn contains(self: *Self, key: K, hash_code: u64) bool {
            if (thread_safety) self.mutex.lockShared();
            defer if (thread_safety) self.mutex.unlockShared();

            return self.map.contains(key, hash_code);
        }

        pub fn count(self: *Self) usize {
            if (thread_safety) self.mutex.lockShared();
            defer if (thread_safety) self.mutex.unlockShared();

            return self.map.count();
        }

        pub fn get(self: *Self, key: K, hash_code: u64) ?V {
            if (thread_safety) self.mutex.lock();
            defer if (thread_safety) self.mutex.unlock();

            if (self.map.get(key, hash_code)) |node| {
                if (self.map.checkTTL(node, hash_code)) {
                    self.removeFromList(node);
                    self.map.pool.release(node);
                    return null;
                }

                // Record access and promote/update node to maintain recency order
                self.sketch.increment(hash_code);
                self.updateOnHit(node);
                return node.value;
            }
            return null;
        }

        pub fn set(self: *Self, key: K, value: V, ttl: ?u64, hash_code: u64) !void {
            if (thread_safety) self.mutex.lock();
            defer if (thread_safety) self.mutex.unlock();

            const node, const found_existing = try self.map.set(key, hash_code);
            node.* = .{
                .key = key,
                .value = value,
                .next = node.next,
                .prev = node.prev,
                .expiry = utils.getExpiry(ttl),
                .data = .{
                    // New items always start in the window region
                    .region = if (found_existing) node.data.region else .Window,
                },
            };

            self.sketch.increment(hash_code);
            if (found_existing) {
                self.updateOnHit(node);
            } else {
                self.insertNew(node);
            }
        }

        pub fn remove(self: *Self, key: K, hash_code: u64) bool {
            if (thread_safety) self.mutex.lock();
            defer if (thread_safety) self.mutex.unlock();

            if (self.map.remove(key, hash_code)) |node| {
                // Remove the node from the respective list as well
                self.removeFromList(node);
                self.map.pool.release(node);
                return true;
            }
            return false;
        }

        fn removeFromList(self: *Self, node: *Node) void {
            switch (node.data.region) {
                .Window => self.window.remove(node),
                .Probationary => self.probationary.remove(node),
                .Protected => self.protected.remove(node),
            }
        }

        fn updateOnHit(self: *Self, node: *Node) void {
            switch (node.data.region) {
                // In window cache, just move to back (most recently used)
                .Window => self.window.moveToBack(node),
                .Probationary => {
                    // Move from probationary to protected, and potentially
                    // demoting a protected item if the cache is full
                    self.probationary.remove(node);
                    if (self.protected.len >= self.protected_size) {
                        const demoted = self.protected.popFirst().?;
                        demoted.data.region = .Probationary;
                        self.probationary.append(demoted);
                    }
                    node.data.region = .Protected;
                    self.protected.append(node);
                },
                // In protected cache, just move to back (most recently used)
                .Protected => self.protected.moveToBack(node),
            }
        }

        fn insertNew(self: *Self, node: *Node) void {
            // If window is full, try to move the oldest window item to main cache
            if (self.window.len >= self.window_size) {
                const victim = self.window.popFirst().?;
                self.tryAdmitToMain(victim);
            }
            self.window.append(node);
        }

        fn tryAdmitToMain(self: *Self, candidate: *Node) void {
            if (self.probationary.len >= self.probationary_size) {
                const victim = self.probationary.first.?;
                // Use TinyLFU sketch to decide whether to admit the candidate
                const victim_hash = utils.hash(K, victim.key);
                const candidate_hash = utils.hash(K, candidate.key);
                if (self.sketch.estimate(victim_hash) > self.sketch.estimate(candidate_hash)) {
                    assert(self.map.remove(candidate.key, candidate_hash) != null);
                    self.map.pool.release(candidate);
                    return;
                }

                assert(self.map.remove(victim.key, null) != null);
                self.probationary.remove(victim);
                self.map.pool.release(victim);
            }

            // Add the window node to probationary segment
            candidate.data.region = .Probationary;
            self.probationary.append(candidate);
        }
    };
}

const testing = std.testing;

const TestCache = utils.TestCache(TinyLFU(u32, []const u8, false));

test "TinyLFU - basic insert and get" {
    var cache = try TestCache.init(testing.allocator, 10);
    defer cache.deinit();

    try cache.set(1, "value1");
    try cache.set(2, "value2");

    try testing.expectEqualStrings("value1", cache.get(1).?);
    try testing.expectEqualStrings("value2", cache.get(2).?);
}

test "TinyLFU - overwrite existing key" {
    var cache = try TestCache.init(testing.allocator, 10);
    defer cache.deinit();

    try cache.set(1, "value1");
    try cache.set(1, "new_value1");

    // Check that the value has been updated
    try testing.expectEqualStrings("new_value1", cache.get(1).?);
}

test "TinyLFU - remove key" {
    var cache = try TestCache.init(testing.allocator, 5);
    defer cache.deinit();

    try cache.set(1, "value1");

    // Remove the key and check that it's no longer present
    try testing.expect(cache.remove(1));
    try testing.expect(cache.get(1) == null);

    // Ensure that a second remove is idempotent
    try testing.expect(!cache.remove(1));
}

test "TinyLFU - eviction and promotion" {
    var cache = try TestCache.init(testing.allocator, 5); // Total size: 5 (window: 1, probationary: 1, protected: 3)
    defer cache.deinit();

    // Fill the cache
    try cache.set(1, "value1"); // 1 moves to window
    try cache.set(2, "value2"); // 2 moves to window, 1 moves to probationary
    _ = cache.get(1); // 1 moves to protected
    try cache.set(3, "value3"); // 3 moves to window, 2 moves to probationary
    _ = cache.get(2); // 2 moves to protected
    try cache.set(4, "value4"); // 4 moves to window, 3 moves to probationary
    _ = cache.get(3); // 3 moves to protected
    try cache.set(5, "value5"); // 5 moves to window, 4 moves to probationary

    // Access 4 multiple times to increase its frequency
    _ = cache.get(4);
    _ = cache.get(4);
    _ = cache.get(4);

    // Insert a new key, which should evict the least frequently used key
    try cache.set(6, "value6"); // 6 moves to window, 5 is compared with 4, 4 moves to protected

    // We expect key 5 to be evicted due to lower frequency
    try testing.expect(cache.get(1) != null);
    try testing.expect(cache.get(2) != null);
    try testing.expect(cache.get(3) != null);
    try testing.expect(cache.get(4) != null);
    try testing.expect(cache.get(5) == null);
    try testing.expect(cache.get(6) != null);
}

test "TinyLFU - TTL functionality" {
    var cache = try TestCache.init(testing.allocator, 5);
    defer cache.deinit();

    try cache.setTTL(1, "value1", 1); // 1ms TTL
    std.time.sleep(2 * std.time.ns_per_ms);
    try testing.expect(cache.get(1) == null);

    try cache.setTTL(2, "value2", 1000); // 1s TTL
    try testing.expect(cache.get(2) != null);
}
