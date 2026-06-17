fn generated_doc_pages() -> i32 {
    let api_page = 1;
    let guide_page = 1;
    api_page + guide_page
}

fn main() {
    let result = generated_doc_pages();
    println!("{}", result);
}
