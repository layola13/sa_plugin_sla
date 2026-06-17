struct Resource {
    owner_id: i32,
}

fn take_ownership(resource: Resource) -> i32 {
    resource.owner_id
}

fn main() {
    let resource = Resource { owner_id: 1 };
    let result = take_ownership(resource);
    println!("{}", result);
}
