mod registry {
    pub fn service_count() -> i32 {
        1
    }
}

use registry as services;

fn main() {
    let result = services::service_count();
    println!("{}", result);
}
