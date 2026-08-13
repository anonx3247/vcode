module vc

import os
import json2
import readline
import time

fn C.getchar() int

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
	defer {
		println('Session: ${if state.meta.name == '' {
			state.meta.id
		} else {
			'${state.meta.name} (${state.meta.id})'
		}}')
	}
	println('Commands: /model, /skill, /resume, /rename, /goal, /review; /quit exits')
	if state.meta.recap != '' { println('Recap: ${state.meta.recap}') }
	mut reader := readline.Readline{}
	reader.enable_raw_mode_nosig()
	defer { reader.disable_raw_mode() }
	keys := chan int{cap: 64}
	events := chan string{cap: 256}
	done := chan TuiTurnCompletion{cap: 1}
	spawn read_tui_keys(keys)
	mut input := ''
	mut busy := false
	redraw_tui_prompt(state, input, busy, '')
	for {
		select {
			key := <-keys {
				if key < 0 { return }
				if key in [10, 13] {
					line := input.trim_space()
					print('\r\x1b[2K${compact_prompt(state.meta.model, state.meta.cwd,
						state.meta.context_percent)}${input}\n')
					input = ''
					if line == '' {
						redraw_tui_prompt(state, input, busy, '')
						continue
					}
					if busy {
						if line.starts_with('/') {
							println('${ansi_dim}command not queued while busy${ansi_reset}')
						} else {
							state.queue << line
							println('${ansi_dim}queued${ansi_reset}')
						}
						redraw_tui_prompt(state, input, busy, '')
						continue
					}
					if line == '/quit' { return }
					if line.starts_with('/review ') {
						busy = true
						spawn run_tui_review_background(state,
							line.all_after('/review ').trim_space(), events, done)
					} else if line.starts_with('/') {
						reader.disable_raw_mode()
						message := handle_tui_command(mut state, line) or {
							eprintln('${err}')
							''
						}
						reader.enable_raw_mode_nosig()
						if message != '' { println(message) }
						if prompt := goal_launch_prompt(line) {
							busy = true
							spawn run_tui_turn_background(state, prompt, events, done)
						}
					} else {
						busy = true
						spawn run_tui_turn_background(state, line, events, done)
					}
					redraw_tui_prompt(state, input, busy, '')
				} else if key == `/` && input == '' && !busy {
					reader.disable_raw_mode()
					input = fzf_select(['/model', '/skill', '/resume', '/rename ', '/goal ',
						'/review ', '/quit'], 'command> ') or { '' }
					reader.enable_raw_mode_nosig()
					redraw_tui_prompt(state, input, busy, '')
				} else if key == 22 {
					reader.disable_raw_mode()
					pasted := clipboard_prompt_text() or { '' }
					reader.enable_raw_mode_nosig()
					input += pasted
					redraw_tui_prompt(state, input, busy, '')
				} else if key in [8, 127] {
					if input.len > 0 {
						runes := input.runes()
						input = runes[..runes.len - 1].string()
					}
					redraw_tui_prompt(state, input, busy, '')
				} else if key == 4 && input == '' {
					return
				} else if key >= 32 && key <= 255 {
					input += u8(key).ascii_str()
					redraw_tui_prompt(state, input, busy, '')
				}
			}
			output := <-events {
				if output.contains('Thinking…') || output == '\r\x1b[2K' {
					frame := if output.contains('Thinking…') {
						sanitize_terminal(output).all_before(' Thinking')
					} else {
						''
					}
					redraw_tui_prompt(state, input, busy, frame)
				} else {
					print('\r\x1b[2K')
					print(output)
					redraw_tui_prompt(state, input, busy, '')
				}
			}
			completion := <-done {
				state.meta = completion.meta
				busy = false
				if completion.error != '' {
					print('\r\x1b[2K')
					eprintln('turn: ${completion.error}')
				}
				if state.queue.len > 0 {
					next := state.queue[0]
					state.queue.delete(0)
					busy = true
					spawn run_tui_turn_background(state, next, events, done)
				}
				redraw_tui_prompt(state, input, busy, '')
			}
		}
	}
}

fn clipboard_prompt_text() !string {
	tmp := os.join_path(os.temp_dir(), 'vc-clipboard-${os.getpid()}-${time.now().unix_nano()}.png')
	$if macos {
		script := 'set imageData to the clipboard as «class PNGf»\nset imageFile to open for access POSIX file "${tmp}" with write permission\nset eof imageFile to 0\nwrite imageData to imageFile\nclose access imageFile'
		result := os.execute('osascript -e ${shell_quote(script)}')
		if result.exit_code == 0 && os.is_file(tmp) && os.file_size(tmp) > 0 {
			return tmp
		}
	}
	text := os.execute('pbpaste')
	if text.exit_code == 0 { return text.output.replace('\r', ' ').replace('\n', ' ') }
	return error('clipboard does not contain text or a PNG image')
}

struct TuiTurnCompletion {
	meta  SessionMeta
	error string
}

fn read_tui_keys(keys chan int) {
	for {
		key := C.getchar()
		keys <- key
		if key < 0 { return }
	}
}

fn redraw_tui_prompt(state TuiState, input string, busy bool, frame string) {
	status := if busy { ' ${ansi_dim}${if frame == '' { '⠋' } else { frame }}${ansi_reset}'
	 } else { ''
	 }
	print('\r\x1b[2K${compact_prompt(state.meta.model, state.meta.cwd, state.meta.context_percent)}${input}${status}')
	if status != '' { print('\x1b[2D') }
	flush_stdout()
}

fn run_tui_turn_background(state TuiState, message string, events chan string, done chan TuiTurnCompletion) {
	mut local := state
	run_tui_turn_with_sink(mut local, message, OutputSink{
		events:      events
		interactive: true
	}) or {
		done <- TuiTurnCompletion{
			meta:  local.meta
			error: err.msg()
		}
		return
	}
	done <- TuiTurnCompletion{
		meta: local.meta
	}
}

fn run_tui_review_background(state TuiState, instructions string, events chan string, done chan TuiTurnCompletion) {
	sink := OutputSink{
		events:      events
		interactive: true
	}
	sink.write('\x1b[1;34mReview started${ansi_reset}\n')
	context := build_review_context(state.meta.cwd, state.meta.model) or {
		sink.write('\x1b[1;31mReview finished · failed${ansi_reset}\n')
		done <- TuiTurnCompletion{
			meta:  state.meta
			error: err.msg()
		}
		return
	}
	cfg := load_config(config_path()) or {
		sink.write('\x1b[1;31mReview finished · failed${ansi_reset}\n')
		done <- TuiTurnCompletion{
			meta:  state.meta
			error: err.msg()
		}
		return
	}
	result := run_review_agent_turn_interactive(state.meta.model, review_prompt(context,
		instructions), context.cwd, cfg, events) or {
		sink.write('\x1b[1;31mReview finished · failed${ansi_reset}\n')
		done <- TuiTurnCompletion{
			meta:  state.meta
			error: err.msg()
		}
		return
	}
	sink.write('\x1b[1;34mReview finished${ansi_reset}\n')
	session_rpc(state.meta.id,
		'{"jsonrpc":"2.0","id":5,"method":"session.append","params":{"kind":"review","data":"${json_escape(result.answer)}"}}') or {
		done <- TuiTurnCompletion{
			meta:  state.meta
			error: err.msg()
		}
		return
	}
	done <- TuiTurnCompletion{
		meta: state.meta
	}
}

fn goal_launch_prompt(command string) ?string {
	if !command.starts_with('/goal ') { return none }
	goal := command['/goal '.len..].trim_space()
	if goal == '' || goal in ['pause', 'resume', 'clear'] { return none }
	return 'Goal: ${goal}\n\nBegin working toward this goal immediately. Use the available tools and continue until the goal is complete or you are genuinely blocked.'
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
			rows := sessions.map('${if it.recap == '' { '(No recap yet)' } else { it.recap }}\t${if it.name == '' {
				it.id
			} else {
				it.name
			}}\t${it.id}\t${it.model}\t${it.cwd}')
			choice := fzf_select(rows, 'resume> ')!
			if choice == '' { return '' }
			fields := choice.split('\t')
			if fields.len < 3 { return error('invalid session selection') }
			id := fields[2]
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
		'/rename' {
			if parts.len != 2 { return error('usage: /rename <name>') }
			name := validate_session_name(parts[1], state.meta.id)!
			request := '{"jsonrpc":"2.0","id":6,"method":"session.rename","params":{"name":"${json_escape(name)}"}}'
			session_rpc(state.meta.id, request) or {
				_ = socket_rpc(state.meta.id,
					'{"jsonrpc":"2.0","id":99,"method":"session.shutdown","params":{}}') or { '' }
				os.rm(socket_path(state.meta.id)) or {}
				start_session_worker(state.meta.id)!
				session_rpc(state.meta.id, request)!
			}
			state.meta.name = name
			return 'session: ${name}'
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
			cfg := load_config(config_path())!
			println('\x1b[1;34mReview started${ansi_reset}')
			result := run_review_agent_turn(state.meta.model, review_prompt(context,
				parts[1..].join(' ')), context.cwd, cfg) or {
				println('\x1b[1;31mReview finished · failed${ansi_reset}')
				return err
			}
			println('\x1b[1;34mReview finished${ansi_reset}')
			_ = session_rpc(state.meta.id,
				'{"jsonrpc":"2.0","id":5,"method":"session.append","params":{"kind":"review","data":"${json_escape(result.answer)}"}}')!
			return ''
		}
		else {
			return error('unknown command: ${parts[0]}')
		}
	}
}

fn run_tui_turn(mut state TuiState, message string) ! {
	return run_tui_turn_with_sink(mut state, message, OutputSink{})
}

fn run_tui_turn_with_sink(mut state TuiState, message string, sink OutputSink) ! {
	_ = session_rpc(state.meta.id,
		'{"jsonrpc":"2.0","id":1,"method":"session.message","params":{"message":"${json_escape(message)}"}}')!
	instructions := load_instructions(state.meta.cwd)!
	cfg := load_config(config_path())!
	context := build_session_context(state.meta.id, instructions.content, state.skill_content,
		message, cfg)!
	prompt := context.prompt
	state.meta.context_percent = context.percent
	_ = session_rpc(state.meta.id,
		'{"jsonrpc":"2.0","id":7,"method":"session.context","params":{"percent":${context.percent}}}') or {
		''
	}
	if checkpoint := context.new_compaction {
		_ = session_rpc(state.meta.id, '{"jsonrpc":"2.0","id":8,"method":"session.append","params":{"kind":"summary_checkpoint","data":"${json_escape(json2.encode(checkpoint,
			escape_unicode: true
		))}"}}')!
		label := if checkpoint.model == '' {
			checkpoint.result
		} else {
			'summarized earlier history'
		}
		sink.write('\x1b[1;34mContext compacted${ansi_reset} ${label}\n')
	}
	result := if sink.interactive {
		run_agent_turn_interactive_restricted(state.meta.model, prompt, state.meta.cwd, cfg,
			state.meta.tools, sink.events)!
	} else {
		run_agent_turn(state.meta.model, prompt, state.meta.cwd, cfg)!
	}
	answer := result.answer
	if result.input_tokens > 0 {
		state.meta.context_percent = min_int(100, result.input_tokens * 100 / 128_000)
		_ = session_rpc(state.meta.id,
			'{"jsonrpc":"2.0","id":9,"method":"session.context","params":{"percent":${state.meta.context_percent}}}') or {
			''
		}
	}
	if !result.streamed { sink.write(answer + '\n') }
	for event in result.history {
		_ = session_rpc(state.meta.id,
			'{"jsonrpc":"2.0","id":2,"method":"session.append","params":{"kind":"${json_escape(event.kind)}","data":"${json_escape(event.data)}"}}')!
	}
	_ = session_rpc(state.meta.id,
		'{"jsonrpc":"2.0","id":3,"method":"session.append","params":{"kind":"assistant","data":"${json_escape(answer)}"}}')!
	refresh_session_recap(mut state, cfg) or { sink.write('recap: ${err}\n') }
	goal := load_goal(state.meta.id)
	if goal.goal != '' && !goal.paused {
		judgement := evaluate_goal_with_fallback(ProviderSmallModel{
			model:  cfg.small_model
			config: cfg
		}, ProviderSmallModel{
			model:  state.meta.model
			config: cfg
		}, goal.goal, answer) or {
			sink.write('goal check: ${err}\n')
			return
		}
		sink.write(judgement + '\n')
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
