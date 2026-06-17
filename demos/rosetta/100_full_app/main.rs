struct AppRequest {
    authenticated: bool,
    route_ok: bool,
    db_ready: bool,
}

fn handle_request(req: AppRequest) -> i32 {
    if !req.authenticated {
        401
    } else if !req.route_ok {
        404
    } else if !req.db_ready {
        503
    } else {
        200
    }
}

fn main() {
    let req = AppRequest { authenticated: true, route_ok: true, db_ready: true };
    println!("{}", handle_request(req));
}
