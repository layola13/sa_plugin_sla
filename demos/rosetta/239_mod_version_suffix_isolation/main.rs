mod codec_v1 {
    pub fn version() -> i32 {
        1
    }
}

mod codec_v2 {
    pub fn version() -> i32 {
        2
    }
}

fn main() {
    let isolated_versions = codec_v2::version() - codec_v1::version() + 1;
    println!("{}", isolated_versions);
}
