fn ci_cd_stages() -> i32 {
    let build = 1;
    let test = 1;
    let publish = 1;
    build + test + publish
}

fn main() {
    let result = ci_cd_stages();
    println!("{}", result);
}
