fn gate_open(arrived: i32, required: i32) -> bool {
    arrived >= required
}

fn main() {
    println!("{}", gate_open(3, 3));
}
