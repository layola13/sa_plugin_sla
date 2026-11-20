// Rust reference for demo 02: the same ownership-transfer handoff,
// expressed with std::sync::mpsc channels. The worker owns both channel
// ends; nothing is borrowed across the thread boundary, so this compiles
// in Rust exactly as it runs in SLA.
use std::sync::mpsc;
use std::thread;

fn main() {
    let (req_tx, req_rx) = mpsc::channel::<u64>();
    let (resp_tx, resp_rx) = mpsc::channel::<u64>();
    let h = thread::spawn(move || {
        for _ in 0..50 {
            let v = req_rx.recv().unwrap();
            resp_tx.send(v + 1).unwrap();
        }
    });
    let mut last: u64 = 0;
    for i in 0..50u64 {
        req_tx.send(i).unwrap();
        last = resp_rx.recv().unwrap();
    }
    h.join().unwrap();
    println!("{}", last);
    assert_eq!(last, 50);
}
