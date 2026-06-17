struct CacheEntry {
    key: i32,
    last_used: i32,
}

fn evict_key(a: CacheEntry, b: CacheEntry) -> i32 {
    if a.last_used < b.last_used { a.key } else { b.key }
}

fn main() {
    println!("{}", evict_key(CacheEntry { key: 10, last_used: 4 }, CacheEntry { key: 20, last_used: 9 }));
}
