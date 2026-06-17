mod helpers {
    pub fn used() -> i32 {
        1
    }

    #[allow(dead_code)]
    pub fn unused() -> i32 {
        1
    }
}

fn main() {
    let used_imports = helpers::used();
    let unused_import_lints = helpers::unused() - used_imports;
    println!("{}", unused_import_lints);
}
