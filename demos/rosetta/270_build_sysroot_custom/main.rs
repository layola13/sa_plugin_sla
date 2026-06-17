fn sysroot_layers() -> i32 {
    let core_layer = 1;
    let std_layer = 1;
    core_layer + std_layer
}

fn main() {
    let result = sysroot_layers();
    println!("{}", result);
}
