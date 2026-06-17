fn sanitizer_flags() -> i32 {
    let address = 1;
    let undefined = 1;
    address + undefined
}

fn main() {
    let result = sanitizer_flags();
    println!("{}", result);
}
