enum ContractError {
    NotFound,
    Denied,
}

fn code(error: ContractError) -> i32 {
    match error {
        ContractError::NotFound => 1,
        ContractError::Denied => 1,
    }
}

fn main() {
    let result = code(ContractError::NotFound) + code(ContractError::Denied);
    println!("{}", result);
}
