enum Allocator {
    System,
    Bump,
}

fn selected_allocator(allocator: Allocator) -> i32 {
    match allocator {
        Allocator::System => 0,
        Allocator::Bump => 1,
    }
}

fn main() {
    let result = selected_allocator(Allocator::Bump);
    println!("{}", result);
}
