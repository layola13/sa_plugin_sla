fn static_library_objects() -> i32 {
    let archive_member = 1;
    archive_member
}

fn main() {
    let result = static_library_objects();
    println!("{}", result);
}
