fn ecs_component_types() -> i32 {
    let transform = 1;
    let velocity = 1;
    let sprite = 1;
    transform + velocity + sprite
}

fn main() {
    let result = ecs_component_types();
    println!("{}", result);
}
