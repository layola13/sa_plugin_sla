fn injected_env_vars() -> i32 {
    let profile_var = 1;
    profile_var
}

fn main() {
    let result = injected_env_vars();
    println!("{}", result);
}
