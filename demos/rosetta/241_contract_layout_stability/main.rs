#[repr(C)]
struct Header {
    tag: i32,
    len: i32,
}

fn stable_field_count() -> i32 {
    let header = Header { tag: 7, len: 9 };
    (header.tag / 7) + (header.len / 9)
}

fn main() {
    let result = stable_field_count();
    println!("{}", result);
}
