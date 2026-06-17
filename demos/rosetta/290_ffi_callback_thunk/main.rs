fn callback_thunks() -> i32 {
    let c_to_rust_thunk = 1;
    c_to_rust_thunk
}

fn main() {
    let result = callback_thunks();
    println!("{}", result);
}
