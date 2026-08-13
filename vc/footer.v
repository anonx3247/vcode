module vc

import os

pub struct RepoLocation {
pub:
	inside bool
	name   string
	folder string
	root   string
}

pub fn detect_repo(cwd string) RepoLocation {
	root_result := run_shell('git rev-parse --show-toplevel', cwd, 2_000_000_000, 4096)
	if root_result.exit_code != 0 { return RepoLocation{
			folder: shorten_home(os.real_path(cwd))
		} }
	output_lines := root_result.output.trim_space().split_into_lines()
	root := output_lines[output_lines.len - 1].trim_space()
	real_cwd := os.real_path(cwd)
	relative := if real_cwd.starts_with(root) {
		real_cwd[root.len..].trim_left('/')
	} else {
		real_cwd
	}
	return RepoLocation{
		inside: true
		name:   os.base(root)
		folder: if relative == '' { '.' } else { relative }
		root:   root
	}
}

pub fn footer(model string, cwd string, pr int) string {
	location := detect_repo(cwd)
	mut parts := [model]
	if location.inside {
		parts << location.name
		parts << location.folder
	} else {
		parts << location.folder
	}
	if pr > 0 { parts << 'PR #${pr}' }
	return parts.join(' • ')
}

pub fn compact_prompt(model string, cwd string, context_percent int) string {
	location := detect_repo(cwd)
	place := if location.inside {
		if location.folder == '.' { location.name } else { '${location.name}/${location.folder}' }
	} else {
		location.folder
	}
	return '\x1b[1;34m${model}${ansi_reset} ${place} ${context_percent}% \x1b[1;34m❯${ansi_reset} '
}

fn shorten_home(path string) string {
	home := os.real_path(os.home_dir())
	return if path == home {
		'~'
	} else if path.starts_with(home + os.path_separator) {
		'~' + path[home.len..]
	} else {
		path
	}
}
