fn checked_ffi_boundary_parts() -> i32 {
    let pointer_checked = 1;
    let length_checked = 1;
    pointer_checked + length_checked
}

fn main() {
    let result = checked_ffi_boundary_parts();
    println!("{}", result);
}
