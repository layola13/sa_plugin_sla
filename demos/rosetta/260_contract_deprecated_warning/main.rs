#[deprecated]
fn old_entry() -> i32 {
    1
}

fn main() {
    #[allow(deprecated)]
    let result = old_entry();
    println!("{}", result);
}
