// Rust reference for demo 01: the same program needs two borrow types.
// read takes &i32 (shared, read-only); modify takes &mut i32 (exclusive).
// Changing read into a writer would force its signature to change, and
// every caller, to change with it. In SLA both functions take &i32.
fn read(value: &i32) {
    println!("{}", value);
}

fn modify(value: &mut i32) {
    *value += 10;
}

fn main() {
    let mut number = 100;
    read(&number);
    modify(&mut number);
    println!("{}", number);
}
