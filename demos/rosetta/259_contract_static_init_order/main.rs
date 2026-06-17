fn init_order_stages() -> i32 {
    let config_loaded = 1;
    let service_started = 1;
    config_loaded + service_started
}

fn main() {
    let result = init_order_stages();
    println!("{}", result);
}
