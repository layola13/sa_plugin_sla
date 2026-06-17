fn kernel_module_hooks() -> i32 {
    let init = 1;
    let exit = 1;
    init + exit
}

fn main() {
    let result = kernel_module_hooks();
    println!("{}", result);
}
