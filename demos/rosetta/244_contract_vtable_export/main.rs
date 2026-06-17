trait Plugin {
    fn init(&self) -> i32;
    fn run(&self) -> i32;
}

struct Worker;

impl Plugin for Worker {
    fn init(&self) -> i32 { 1 }
    fn run(&self) -> i32 { 1 }
}

fn main() {
    let plugin = Worker;
    let result = plugin.init() + plugin.run();
    println!("{}", result);
}
