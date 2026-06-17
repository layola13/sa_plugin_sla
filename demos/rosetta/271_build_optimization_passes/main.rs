fn optimization_passes() -> i32 {
    let inline_pass = 1;
    let dce_pass = 1;
    let const_fold_pass = 1;
    inline_pass + dce_pass + const_fold_pass
}

fn main() {
    let result = optimization_passes();
    println!("{}", result);
}
