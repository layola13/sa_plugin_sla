fn eval_line(line: &str) -> i32 {
    match line {
        ":quit" => 0,
        "help" => 1,
        _ => 2,
    }
}

fn main() {
    println!("{}", eval_line("help"));
}
