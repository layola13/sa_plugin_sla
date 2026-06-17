macro_rules! exported_answer {
    () => { 1 };
}

fn main() {
    let result = exported_answer!();
    println!("{}", result);
}
