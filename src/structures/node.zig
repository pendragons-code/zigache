/// Node represents an entry in the cache.
/// It contains the key-value pair, linked list pointers, expiration information,
/// and additional data specific to the caching algorithm.
pub fn Node(comptime K: type, comptime V: type, comptime Data: type) type {
    return struct {
        const Self = @This();

        key: K,
        value: V,

        /// Pointer to the next node in the linked list
        next: ?*Self = null,
        // Pointer to the previous node in the linked list
        prev: ?*Self = null,

        /// The expiry field stores the timestamp when this cache entry should expire, in milliseconds.
        /// It is of type `?i64`, where:
        /// - `null` indicates that the entry does not expire
        /// - A non-null value represents the expiration time as a Unix timestamp
        ///   (milliseconds since the Unix epoch)
        ///
        /// This field is used in TTL (Time-To-Live) operations to determine if an entry
        /// should be considered valid or if it should be removed from the cache.
        expiry: ?i64 = null,

        /// Additional data specific to the caching algorithm (e.g., frequency counters, flags)
        data: Data,
    };
}
