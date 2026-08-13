module vc

import os
import time

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
	if state.meta.recap != '' { println('Recap: ${state.meta.recap}') }
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
		run_tui_turn(mut state, line) or {
			eprintln('turn: ${err}')
			continue
		}
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
			rows :=
				sessions.map('${if it.recap == '' { '(No recap yet)' } else { it.recap }}\t${it.id}\t${it.model}\t${it.cwd}')
			choice := fzf_select(rows, 'resume> ')!
			if choice == '' { return '' }
			fields := choice.split('\t')
			if fields.len < 2 { return error('invalid session selection') }
			id := fields[1]
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
			return if resumed.recap == '' { 'resumed ${id}' } else { 'Recap: ${resumed.recap}' }
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
	_ = session_rpc(state.meta.id,
		'{"jsonrpc":"2.0","id":1,"method":"session.message","params":{"message":"${json_escape(message)}"}}')!
	instructions := load_instructions(state.meta.cwd)!
	cfg := load_config(config_path())!
	prompt := build_session_prompt(state.meta.id, instructions.content, state.skill_content,
		message, cfg)!
	result := run_agent_turn(state.meta.model, prompt, state.meta.cwd, cfg)!
	answer := result.answer
	if !result.streamed { println(answer) }
	for event in result.history {
		_ = session_rpc(state.meta.id,
			'{"jsonrpc":"2.0","id":2,"method":"session.append","params":{"kind":"${json_escape(event.kind)}","data":"${json_escape(event.data)}"}}')!
	}
	_ = session_rpc(state.meta.id,
		'{"jsonrpc":"2.0","id":3,"method":"session.append","params":{"kind":"assistant","data":"${json_escape(answer)}"}}')!
	refresh_session_recap(mut state, cfg) or { eprintln('recap: ${err}') }
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

fn refresh_session_recap(mut state TuiState, cfg Config) ! {
	now := time.now().unix_milli()
	if state.meta.recap != '' && now - state.meta.recap_ms < 10 * 60 * 1000 { return }
	transcript := session_recap_source(state.meta.id)!
	if transcript == '' { return }
	small_ref := parse_model_ref(cfg.small_model)!
	model := if small_ref.provider in cfg.providers { cfg.small_model } else { state.meta.model }
	recap := generate_recap(ProviderSmallModel{
		model:  model
		config: cfg
	}, transcript)!
	if recap == '' { return }
	_ = session_rpc(state.meta.id,
		'{"jsonrpc":"2.0","id":4,"method":"session.recap","params":{"recap":"${json_escape(recap)}"}}')!
	state.meta.recap = recap
	state.meta.recap_ms = now
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
