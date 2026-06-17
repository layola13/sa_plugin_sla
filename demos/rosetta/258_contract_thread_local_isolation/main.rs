fn isolated_thread_slots() -> i32 {
    let main_thread_slot = 1;
    let worker_thread_slot = 1;
    main_thread_slot + worker_thread_slot
}

fn main() {
    let result = isolated_thread_slots();
    println!("{}", result);
}
