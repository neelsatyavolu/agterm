//! Running a command line the way a person would at this computer's prompt: PowerShell on
//! Windows (pwsh 7 when installed, else Windows PowerShell), `/bin/sh` elsewhere (tests).

use std::{path::Path, process::Command};

/// "pwsh", "powershell" or "sh".
pub fn name() -> &'static str {
    if !cfg!(windows) {
        "sh"
    } else if find_on_path("pwsh.exe") {
        "pwsh"
    } else {
        "powershell"
    }
}

fn find_on_path(exe: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|path| std::env::split_paths(&path).any(|dir| dir.join(exe).is_file()))
}

/// The script PowerShell runs: UTF-8 output, then the command, then an exit status that
/// reflects it, as `sh -c` would: the last native program's exit code, else 1 if the last
/// statement failed. `$?` is read straight after the command, before anything resets it.
pub fn powershell_script(command: &str) -> String {
    format!(
        "[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)\n\
         $OutputEncoding = [Console]::OutputEncoding\n\
         $global:LASTEXITCODE = 0\n\
         {command}\n\
         $agtermOk = $?\n\
         if ($global:LASTEXITCODE) {{ exit $global:LASTEXITCODE }} elseif (-not $agtermOk) {{ exit 1 }} else {{ exit 0 }}\n"
    )
}

/// `-EncodedCommand` takes base64 of UTF-16LE, which sidesteps Windows command-line quoting.
pub fn encoded(script: &str) -> String {
    let bytes: Vec<u8> = script.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
    openssl::base64::encode_block(&bytes)
}

/// The process for `command` in `cwd`. Pipes and process-group settings are the caller's.
pub fn command(cwd: &Path, command: &str) -> Command {
    let mut cmd = if cfg!(windows) {
        let mut cmd = Command::new(format!("{}.exe", name()));
        cmd.args(["-NoLogo", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand"])
            .arg(encoded(&powershell_script(command)));
        cmd
    } else {
        let mut cmd = Command::new("/bin/sh");
        cmd.arg("-c").arg(command);
        cmd
    };
    cmd.current_dir(cwd);
    cmd
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn script_runs_the_command_then_reports_its_status() {
        let script = powershell_script("cargo test");
        let lines: Vec<&str> = script.lines().collect();
        assert_eq!(lines[3], "cargo test");
        assert_eq!(lines[4], "$agtermOk = $?");
        assert!(lines[5].starts_with("if ($global:LASTEXITCODE) { exit $global:LASTEXITCODE }"));
    }

    #[test]
    fn encodes_utf16le_base64() {
        // "A" is 41 00 in UTF-16LE.
        assert_eq!(encoded("A"), "QQA=");
    }
}
