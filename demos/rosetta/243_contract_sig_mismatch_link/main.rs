fn expected_arg_count() -> i32 {
    2
}

fn provided_arg_count() -> i32 {
    1
}

fn main() {
    let mismatch_count = expected_arg_count() - provided_arg_count();
    println!("{}", mismatch_count);
}
