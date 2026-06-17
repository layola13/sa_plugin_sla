fn wasm_targets() -> i32 {
    let wasm32_unknown_unknown = 1;
    wasm32_unknown_unknown
}

fn main() {
    let result = wasm_targets();
    println!("{}", result);
}
