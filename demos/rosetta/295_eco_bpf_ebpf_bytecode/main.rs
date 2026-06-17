fn ebpf_instruction_kinds() -> i32 {
    let load = 1;
    let return_op = 1;
    load + return_op
}

fn main() {
    let result = ebpf_instruction_kinds();
    println!("{}", result);
}
