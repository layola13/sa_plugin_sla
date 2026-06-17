trait Plugin {
    fn enabled(&self) -> i32;
}

struct Formatter;
struct Analyzer;

impl Plugin for Formatter {
    fn enabled(&self) -> i32 { 1 }
}

impl Plugin for Analyzer {
    fn enabled(&self) -> i32 { 1 }
}

fn main() {
    let result = Formatter.enabled() + Analyzer.enabled();
    println!("{}", result);
}
