fn harness_tests() -> i32 {
    let unit_test = 1;
    let integration_test = 1;
    unit_test + integration_test
}

fn main() {
    let result = harness_tests();
    println!("{}", result);
}
