fn linked_libc_symbols() -> i32 {
    let puts_symbol = 1;
    puts_symbol
}

fn main() {
    let result = linked_libc_symbols();
    println!("{}", result);
}
