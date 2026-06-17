fn critical_path(root: i32, left: i32, right: i32) -> i32 {
    root + left.max(right)
}

fn main() {
    println!("{}", critical_path(4, 7, 3));
}
