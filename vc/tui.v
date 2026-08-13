module vc

import os

pub struct TuiState {
pub mut:
	meta           SessionMeta
	busy           bool
	queue          []string
	interrupted    bool
	goal_paused    bool
	last_escape_ms i64
	active_skill   string
	skill_content  string
}

pub fn (mut state TuiState) submit(text string) ?string {
	if state.busy {
		state.queue << text
		return none
	}
	state.busy = true
	return text
}

pub fn (mut state TuiState) complete() ?string {
	state.busy = false
	if state.queue.len == 0 { return none }
	next := state.queue[0]
	state.queue.delete(0)
	state.busy = true
	return next
}

pub fn (mut state TuiState) escape(now_ms i64) string {
	if now_ms - state.last_escape_ms <= 350 {
		state.goal_paused = true
		state.busy = false
		state.queue.clear()
		state.last_escape_ms = 0
		return 'cancel'
	}
	state.last_escape_ms = now_ms
	state.interrupted = true
	return 'interrupt'
}

pub fn run_tui(meta SessionMeta) ! {
	mut state := TuiState{
		meta: meta
	}
	defer { println('Session: ${state.meta.id}') }
	println(footer(state.meta.model, state.meta.cwd, 0))
	println('Commands: /model [model], /skill [skill-name], /resume, /goal, /review; /quit exits')
	for {
		print('> ')
		line := os.get_line().trim_space()
		if line == '' { continue
		 }
		if line == '/quit' { return }
		if line.starts_with('/') {
			message := handle_tui_command(mut state, line) or {
				eprintln('${err}')
				continue
			}
			if message != '' { println(message) }
			continue
		}
		run_tui_turn(mut state, line)!
	}
}

pub fn handle_tui_command(mut state TuiState, command string) !string {
	parts := command.split(' ')
	match parts[0] {
		'/model' {
			choice := if parts.len > 1 {
				parts[1]
			} else {
				fzf_select(available_models()!, 'model> ')!
			}
			if choice == '' { return '' }
			parse_model_ref(choice)!
			state.meta.model = choice
			save_session_meta(state.meta)!
			if os.exists(socket_path(state.meta.id)) {
				_ = socket_rpc(state.meta.id,
					'{"jsonrpc":"2.0","id":1,"method":"session.model","params":{"model":"${json_escape(choice)}"}}') or {
					''
				}
			}
			return 'model: ${choice}'
		}
		'/skill' {
			skills := discover_skills(state.meta.cwd)
			names := skills.map(it.name)
			choice := if parts.len > 1 { parts[1] } else { fzf_select(names, 'skill> ')! }
			for skill in skills {
				if skill.name == choice {
					state.active_skill = choice
					state.skill_content = os.read_file(skill.path)!
					return 'skill loaded: ${choice}'
				}
			}
			return error('unknown skill: ${choice}')
		}
		'/resume' {
			sessions := list_sessions()!
			rows := sessions.map('${it.id}\t${it.model}\t${it.cwd}\t${it.recap}')
			choice := fzf_select(rows, 'resume> ')!
			if choice == '' { return '' }
			id := choice.all_before('\t')
			mut resumed := load_session_meta(id)!
			if resumed.cwd != os.real_path(os.getwd()) {
				print('Move session from ${resumed.cwd} to ${os.getwd()}? [y/N] ')
				if os.get_line().trim_space().to_lower() in ['y', 'yes'] {
					mut worker := new_session_worker(resumed)!
					_ =
						worker.handle_rpc('{"jsonrpc":"2.0","id":1,"method":"session.move","params":{"cwd":"${json_escape(os.getwd())}"}}')
					resumed = worker.meta
				}
			}
			state.meta = resumed
			start_session_worker(id) or {}
			return 'resumed ${id}'
		}
		'/goal' {
			mut goal := load_goal(state.meta.id)
			action := if parts.len > 1 { parts[1..].join(' ') } else { '' }
			match action {
				'pause' {
					goal.paused = true
				}
				'resume' {
					goal.paused = false
				}
				'clear' {
					goal = GoalState{}
				}
				'' {
					return if goal.goal == '' { 'no active goal' } else { '${if goal.paused {
							'paused'
						} else {
							'active'
						}}: ${goal.goal}'
					 }
				}
				else {
					goal = GoalState{
						goal: action
					}
				}
			}

			save_goal(state.meta.id, goal)!
			return if goal.goal == '' { 'goal cleared' } else { 'goal ${if goal.paused {
					'paused'
				} else {
					'active'
				}}: ${goal.goal}'
			 }
		}
		'/review' {
			if parts.len == 1 { return error('usage: /review <instructions>') }
			context := build_review_context(state.meta.cwd, state.meta.model)!
			return run_review(ProviderSmallModel{
				model:  state.meta.model
				config: load_config(config_path())!
			}, context, parts[1..].join(' '))!
		}
		else {
			return error('unknown command: ${parts[0]}')
		}
	}
}

fn run_tui_turn(mut state TuiState, message string) ! {
	if os.exists(socket_path(state.meta.id)) {
		_ = socket_rpc(state.meta.id,
			'{"jsonrpc":"2.0","id":1,"method":"session.message","params":{"message":"${json_escape(message)}"}}') or {
			''
		}
	}
	instructions := load_instructions(state.meta.cwd)!
	mut prompt := instructions.content
	if state.skill_content != '' {
		prompt += '\nThe user explicitly activated this skill:\n' + state.skill_content
	}
	prompt += '\nUser request:\n' + message
	result := run_agent_turn(state.meta.model, prompt, state.meta.cwd, load_config(config_path())!)!
	answer := result.answer
	if !result.streamed { println(answer) }
	if os.exists(socket_path(state.meta.id)) {
		_ = socket_rpc(state.meta.id,
			'{"jsonrpc":"2.0","id":2,"method":"session.append","params":{"kind":"assistant","data":"${json_escape(answer)}"}}') or {
			''
		}
	}
	goal := load_goal(state.meta.id)
	if goal.goal != '' && !goal.paused {
		judgement := evaluate_goal(ProviderSmallModel{
			model:  load_config(config_path())!.small_model
			config: load_config(config_path())!
		}, goal.goal, answer)!
		println(judgement)
		if judgement.trim_space() == '<goal achieved>' { save_goal(state.meta.id, GoalState{})! }
	}
}

pub fn available_models() ![]string {
	return model_catalog(load_config(config_path())!)!
}

pub fn fzf_select(items []string, prompt string) !string {
	if items.len == 0 { return '' }
	path := os.find_abs_path_of_executable('fzf') or {
		return error('fzf is required for TUI selection')
	}
	tmp_dir := os.join_path(os.temp_dir(), 'vc-fzf-${os.getpid()}')
	os.mkdir_all(tmp_dir)!
	defer { os.rmdir_all(tmp_dir) or {} }
	input := os.join_path(tmp_dir, 'items')
	output := os.join_path(tmp_dir, 'selected')
	os.write_file(input, items.join('\n') + '\n')!
	code :=
		os.system('${shell_quote(path)} --height=40% --reverse --prompt=${shell_quote(prompt)} < ${shell_quote(input)} > ${shell_quote(output)}')
	selected := os.read_file(output) or { '' }.trim_space()
	if code !in [0, 1, 130] { return error('fzf exited with ${code}') }
	return selected
}

fn shell_quote(value string) string {
	return "'" + value.replace("'", "'\\''") + "'"
}
