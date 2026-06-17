fn pkg_config_fields() -> i32 {
    let include_dir = 1;
    let library_dir = 1;
    include_dir + library_dir
}

fn main() {
    let result = pkg_config_fields();
    println!("{}", result);
}
