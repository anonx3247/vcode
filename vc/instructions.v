module vc

import os

const instruction_names = ['AGENTS.md', 'AGENT.md', 'CLAUDE.md']

pub struct InstructionSet {
pub mut:
	files   []string
	content string
}

pub fn load_instructions(cwd string) !InstructionSet {
	mut result := InstructionSet{}
	mut dirs := []string{}
	mut dir := os.real_path(cwd)
	for {
		dirs.prepend(dir)
		parent := os.dir(dir)
		if parent == dir { break
		 }
		dir = parent
	}
	home := os.real_path(os.home_dir())
	if home !in dirs { dirs.prepend(home) }
	mut visited := map[string]bool{}
	for candidate_dir in dirs {
		for name in instruction_names {
			path := os.join_path(candidate_dir, name)
			if os.is_file(path) {
				load_instruction_file(path, mut visited, mut result)!
			}
		}
	}
	return result
}

fn load_instruction_file(path string, mut visited map[string]bool, mut result InstructionSet) ! {
	real := os.real_path(path)
	if visited[real] { return }
	visited[real] = true
	result.files << real
	for line in os.read_lines(real)! {
		trimmed := line.trim_space()
		if trimmed.starts_with('@') && !trimmed.contains(' ') {
			imported := os.real_path(os.join_path(os.dir(real), trimmed[1..]))
			if os.is_file(imported) {
				load_instruction_file(imported, mut visited, mut result)!
				continue
			}
		}
		result.content += line + '\n'
	}
}
