fn zig_exported_symbols() -> i32 {
    let exported_entry = 1;
    exported_entry
}

fn main() {
    let result = zig_exported_symbols();
    println!("{}", result);
}
