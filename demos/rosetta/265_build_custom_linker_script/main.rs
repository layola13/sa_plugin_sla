fn linker_sections() -> i32 {
    let text_section = 1;
    let data_section = 1;
    text_section + data_section
}

fn main() {
    let result = linker_sections();
    println!("{}", result);
}
