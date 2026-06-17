mod leaf {
    pub fn exported_items() -> i32 {
        1
    }
}

mod middle {
    pub fn reachable_items() -> i32 {
        super::leaf::exported_items()
    }
}

fn main() {
    let result = middle::reachable_items();
    println!("{}", result);
}
