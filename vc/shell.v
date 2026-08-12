module vc

import os
import time

pub struct ShellResult {
pub:
	output    string
	exit_code int
	timed_out bool
}

pub fn run_shell(command string, cwd string, timeout time.Duration, max_output int) ShellResult {
	mut process := os.new_process('/bin/zsh')
	process.set_args(['-lic', command])
	process.set_work_folder(cwd)
	process.set_redirect_stdio()
	process.use_pgroup = true
	process.run()
	started := time.now()
	mut output := ''
	limit := if max_output > 0 { max_output } else { 1024 * 1024 }
	mut timed_out := false
	for process.is_alive() {
		output = append_bounded(output, process.stdout_read() + process.stderr_read(), limit)
		if timeout > 0 && time.since(started) >= timeout {
			timed_out = true
			process.signal_pgkill()
			break
		}
		time.sleep(10 * time.millisecond)
	}
	process.wait()
	output = append_bounded(output, process.stdout_slurp() + process.stderr_slurp(), limit)
	code := process.code
	process.close()
	return ShellResult{
		output:    output
		exit_code: code
		timed_out: timed_out
	}
}

fn append_bounded(current string, addition string, max_bytes int) string {
	combined := current + addition
	if combined.len <= max_bytes { return combined }
	marker := '\n[... output truncated ...]\n'
	keep := max_bytes - marker.len
	if keep <= 0 { return marker[..max_bytes] }
	return marker + combined[combined.len - keep..]
}
