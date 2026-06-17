mod local {
    pub fn priority() -> i32 {
        1
    }
}

fn priority() -> i32 {
    2
}

fn main() {
    let local_module_wins = local::priority();
    let root_item = priority();
    let result = root_item - local_module_wins;
    println!("{}", result);
}
