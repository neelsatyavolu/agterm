//! Real-model check. Runs only with `AGL_E2E=1` and a local model server running
//! (endpoint and model from the usual config/env/detection).

use std::process::Command;

#[test]
fn fixes_a_bug_with_a_local_model() {
    if std::env::var("AGL_E2E").as_deref() != Ok("1") {
        eprintln!("skipped: set AGL_E2E=1 to run");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("add.py"), "def add(a, b):\n    return a - b\n\nprint(add(2, 3))\n").unwrap();
    let home = tempfile::tempdir().unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_agl"))
        .args(["-p", "add.py has a bug. Fix it, then run it with python3 to check it prints 5."])
        .env("AGL_HOME", home.path())
        .current_dir(dir.path())
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    eprintln!("{stdout}\n{}", String::from_utf8_lossy(&out.stderr));
    assert!(out.status.success());
    let fixed = std::fs::read_to_string(dir.path().join("add.py")).unwrap();
    assert!(fixed.contains("a + b") || fixed.contains("a+b"), "{fixed}");
    assert!(stdout.contains("bash"), "model never ran the program");
}
