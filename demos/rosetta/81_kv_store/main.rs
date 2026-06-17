use std::collections::BTreeMap;

fn main() {
    let mut kv = BTreeMap::new();
    kv.insert("alpha", 5);
    kv.insert("beta", 8);
    println!("{}", kv["beta"]);
}
