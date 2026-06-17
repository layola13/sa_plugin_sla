fn embedded_no_os_hooks() -> i32 {
    let reset_handler = 1;
    reset_handler
}

fn main() {
    let result = embedded_no_os_hooks();
    println!("{}", result);
}
