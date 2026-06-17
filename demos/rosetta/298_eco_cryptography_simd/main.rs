fn crypto_simd_lanes() -> i32 {
    let lane0 = 1;
    let lane1 = 1;
    let lane2 = 1;
    let lane3 = 1;
    lane0 + lane1 + lane2 + lane3
}

fn main() {
    let result = crypto_simd_lanes();
    println!("{}", result);
}
