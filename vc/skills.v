module vc

import os

pub struct Skill {
pub:
	name string
	path string
}

pub fn discover_skills(cwd string) []Skill {
	mut roots := []string{}
	for base in [os.home_dir(), os.real_path(cwd)] {
		for agent_dir in ['.agents', '.codex', '.claude'] {
			roots << os.join_path(base, agent_dir, 'skills')
		}
	}
	mut found := map[string]Skill{}
	for root in roots {
		if !os.is_dir(root) { continue
		 }
		for name in os.ls(root) or { continue } {
			path := os.join_path(root, name, 'SKILL.md')
			if os.is_file(path) {
				found[name] = Skill{
					name: name
					path: os.real_path(path)
				}
			}
		}
	}
	return found.values()
}
