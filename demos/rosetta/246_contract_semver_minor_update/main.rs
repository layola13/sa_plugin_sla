struct ApiV1 {
    stable: i32,
}

struct ApiV1_1 {
    stable: i32,
    added: i32,
}

fn main() {
    let old = ApiV1 { stable: 1 };
    let new = ApiV1_1 { stable: old.stable, added: 1 };
    println!("{}", new.added);
}
