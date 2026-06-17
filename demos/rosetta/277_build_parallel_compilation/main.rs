fn parallel_codegen_units() -> i32 {
    let parser = 1;
    let checker = 1;
    let optimizer = 1;
    let emitter = 1;
    parser + checker + optimizer + emitter
}

fn main() {
    let result = parallel_codegen_units();
    println!("{}", result);
}
