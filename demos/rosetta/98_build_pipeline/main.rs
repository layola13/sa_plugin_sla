fn artifact_count(compiled: bool, tests_passed: bool, docs_built: bool) -> i32 {
    if compiled && tests_passed {
        1 + i32::from(docs_built)
    } else {
        0
    }
}

fn main() {
    println!("{}", artifact_count(true, true, true));
}
