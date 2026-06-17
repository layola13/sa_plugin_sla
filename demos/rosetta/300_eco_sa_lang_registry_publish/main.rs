fn registry_publish_steps() -> i32 {
    let package = 1;
    let checksum = 1;
    let index = 1;
    package + checksum + index
}

fn main() {
    let result = registry_publish_steps();
    println!("{}", result);
}
