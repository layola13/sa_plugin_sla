fn lsp_message_kinds() -> i32 {
    let request = 1;
    let response = 1;
    request + response
}

fn main() {
    let result = lsp_message_kinds();
    println!("{}", result);
}
