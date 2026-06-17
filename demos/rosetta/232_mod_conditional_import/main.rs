#[cfg(unix)]
fn selected_platform_module() -> i32 {
    1
}

#[cfg(not(unix))]
fn selected_platform_module() -> i32 {
    0
}

fn main() {
    let result = selected_platform_module();
    println!("{}", result);
}
