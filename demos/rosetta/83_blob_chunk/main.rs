fn chunk_count(bytes: i32, chunk_size: i32) -> i32 {
    (bytes + chunk_size - 1) / chunk_size
}

fn main() {
    println!("{}", chunk_count(10, 4));
}
