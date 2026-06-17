fn rust_staticlib_exports() -> i32 {
    let add_symbol = 1;
    add_symbol
}

fn main() {
    let result = rust_staticlib_exports();
    println!("{}", result);
}
