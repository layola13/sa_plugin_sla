fn bundled_assets() -> i32 {
    let manifest = 1;
    let shader = 1;
    let config = 1;
    manifest + shader + config
}

fn main() {
    let result = bundled_assets();
    println!("{}", result);
}
