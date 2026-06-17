mod c_api {
    pub fn grouped_symbol_count() -> i32 {
        let open_symbol = 1;
        let close_symbol = 1;
        open_symbol + close_symbol
    }
}

fn main() {
    let result = c_api::grouped_symbol_count();
    println!("{}", result);
}
