mod routes {
    pub fn endpoint_count() -> i32 {
        let index_route = 1;
        let health_route = 1;
        index_route + health_route
    }
}

fn main() {
    let result = routes::endpoint_count();
    println!("{}", result);
}
