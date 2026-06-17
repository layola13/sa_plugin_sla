fn cxx_symbol_names() -> i32 {
    let mangled_name = 1;
    let extern_c_shim = 1;
    mangled_name + extern_c_shim
}

fn main() {
    let result = cxx_symbol_names();
    println!("{}", result);
}
