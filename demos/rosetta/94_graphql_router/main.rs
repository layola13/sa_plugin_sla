fn resolver_id(operation: &str, field: &str) -> i32 {
    match (operation, field) {
        ("query", "user") => 11,
        ("mutation", "createUser") => 21,
        _ => 0,
    }
}

fn main() {
    println!("{}", resolver_id("query", "user"));
}
