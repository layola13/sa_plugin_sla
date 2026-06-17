fn windows_targets() -> i32 {
    let x86_64_pc_windows_msvc = 1;
    x86_64_pc_windows_msvc
}

fn main() {
    let result = windows_targets();
    println!("{}", result);
}
