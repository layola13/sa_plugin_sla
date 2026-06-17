fn enabled_log_levels() -> i32 {
    let info = 1;
    let warn = 1;
    let error = 1;
    info + warn + error
}

fn main() {
    let result = enabled_log_levels();
    println!("{}", result);
}
