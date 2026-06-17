fn wasm_host_imports() -> i32 {
    let log_import = 1;
    let clock_import = 1;
    log_import + clock_import
}

fn main() {
    let result = wasm_host_imports();
    println!("{}", result);
}
