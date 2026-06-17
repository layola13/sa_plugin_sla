fn on_event(value: i32) -> i32 {
    value
}

fn register(callback: fn(i32) -> i32) -> i32 {
    callback(1)
}

fn main() {
    let result = register(on_event);
    println!("{}", result);
}
