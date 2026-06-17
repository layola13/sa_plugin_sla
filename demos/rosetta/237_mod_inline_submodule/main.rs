mod inline_child {
    pub fn layer_count() -> i32 {
        1
    }
}

fn main() {
    let result = inline_child::layer_count();
    println!("{}", result);
}
