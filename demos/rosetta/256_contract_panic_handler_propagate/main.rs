fn panic_route_hops() -> i32 {
    let local_handler = 1;
    let host_handler = 1;
    local_handler + host_handler
}

fn main() {
    let result = panic_route_hops();
    println!("{}", result);
}
