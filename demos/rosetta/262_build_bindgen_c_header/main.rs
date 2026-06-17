fn generated_bindings() -> i32 {
    let type_decl = 1;
    let function_decl = 1;
    type_decl + function_decl
}

fn main() {
    let result = generated_bindings();
    println!("{}", result);
}
