struct Task {
    deps_done: bool,
    priority: i32,
}

fn ready_score(task: Task) -> i32 {
    if task.deps_done { task.priority } else { 0 }
}

fn main() {
    let task = Task { deps_done: true, priority: 7 };
    println!("{}", ready_score(task));
}
