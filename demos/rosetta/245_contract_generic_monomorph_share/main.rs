fn identity<T>(value: T) -> T {
    value
}

fn main() {
    let int_path = identity(1_i32);
    let bool_path = if identity(true) { 1 } else { 0 };
    println!("{}", int_path + bool_path);
}
