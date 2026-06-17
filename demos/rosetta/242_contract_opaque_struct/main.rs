mod api {
    pub struct Handle(i32);

    pub fn new_handle() -> Handle {
        Handle(1)
    }

    pub fn is_live(handle: &Handle) -> i32 {
        handle.0
    }
}

fn main() {
    let handle = api::new_handle();
    let result = api::is_live(&handle);
    println!("{}", result);
}
