module vc

import os
import time

pub struct ShellResult {
pub:
	output    string
	exit_code int
	timed_out bool
}

@[heap]
pub struct ShellJob {
pub:
	id string
mut:
	process     &os.Process = unsafe { nil }
	output      string
	base_cursor u64
	done        bool
	exit_code   int = -1
}

pub struct JobRead {
pub:
	output      string
	next_cursor u64
	done        bool
	exit_code   int
	truncated   bool
}

pub struct ShellJobManager {
pub:
	max_output int = 1024 * 1024
pub mut:
	jobs map[string]&ShellJob
	next u64 = 1
}

pub fn (mut manager ShellJobManager) start(command string, cwd string) !string {
	id := 'job-${manager.next}'
	manager.next++
	mut process := os.new_process(login_shell())
	process.set_args(['-lc', command])
	process.set_work_folder(cwd)
	process.set_redirect_stdio()
	process.use_pgroup = true
	process.run()
	manager.jobs[id] = &ShellJob{
		id:      id
		process: process
	}
	return id
}

pub fn (mut manager ShellJobManager) read(id string, cursor u64) !JobRead {
	mut job := manager.jobs[id] or { return error('unknown job: ${id}') }
	if !job.done {
		append_job_output(mut job, job.process.stdout_read() + job.process.stderr_read(),
			manager.max_output)
		if !job.process.is_alive() {
			job.process.wait()
			append_job_output(mut job, job.process.stdout_slurp() + job.process.stderr_slurp(),
				manager.max_output)
			job.done = true
			job.exit_code = job.process.code
			job.process.close()
		}
	}
	end := job.base_cursor + u64(job.output.len)
	start := if cursor < job.base_cursor { 0 } else { int(cursor - job.base_cursor) }
	return JobRead{
		output:      job.output[start..]
		next_cursor: end
		done:        job.done
		exit_code:   job.exit_code
		truncated:   cursor < job.base_cursor
	}
}

pub fn (mut manager ShellJobManager) cancel(id string) ! {
	mut job := manager.jobs[id] or { return error('unknown job: ${id}') }
	if !job.done && job.process.is_alive() { job.process.signal_pgkill() }
}

fn append_job_output(mut job ShellJob, addition string, limit int) {
	job.output += addition
	if job.output.len > limit {
		drop := job.output.len - limit
		job.output = job.output[drop..]
		job.base_cursor += u64(drop)
	}
}

pub fn run_shell(command string, cwd string, timeout time.Duration, max_output int) ShellResult {
	mut process := os.new_process(login_shell())
	process.set_args(['-lc', command])
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

fn login_shell() string {
	configured := os.getenv('SHELL')
	if configured != '' && os.is_executable(configured) { return configured }
	for candidate in ['/bin/zsh', '/bin/bash', '/bin/sh'] {
		if os.is_executable(candidate) { return candidate }
	}
	return '/bin/sh'
}

fn append_bounded(current string, addition string, max_bytes int) string {
	combined := current + addition
	if combined.len <= max_bytes { return combined }
	marker := '\n[... output truncated ...]\n'
	keep := max_bytes - marker.len
	if keep <= 0 { return marker[..max_bytes] }
	return marker + combined[combined.len - keep..]
}
