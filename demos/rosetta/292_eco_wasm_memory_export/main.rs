fn wasm_memory_exports() -> i32 {
    let linear_memory = 1;
    linear_memory
}

fn main() {
    let result = wasm_memory_exports();
    println!("{}", result);
}
