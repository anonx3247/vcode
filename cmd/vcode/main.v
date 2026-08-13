module main

import os
import vc

fn main() {
	run(os.args[1..]) or {
		eprintln('vc: ${err}')
		exit(1)
	}
}

fn run(args []string) ! {
	if args.len > 0 && args[0] in ['--help', '-h', 'help'] {
		print_help()
		return
	}
	if args.len > 0 && args[0] == '--worker' {
		if args.len != 2 { return error('usage: vc --worker <session-id>') }
		$if !windows {
			os.fd_close(0)
			os.fd_close(1)
			os.fd_close(2)
		}
		vc.serve_session(args[1])!
		return
	}
	if args.len > 0 && args[0] == '--rpc' {
		run_stdio_rpc()!
		return
	}
	if args.len > 0 && args[0] == 'model' {
		run_model(args[1..])!
		return
	}
	if args.len > 0 && args[0] == 'small-model' {
		run_small_model(args[1..])!
		return
	}
	if args.len > 0 && args[0] == 'session' {
		run_session(args[1..])!
		return
	}
	if args.len > 0 && args[0] == 'resume' {
		run_resume(args[1..])!
		return
	}
	if '-p' in args {
		run_scripted(args)!
		return
	}
	if args.len == 0 {
		start_empty_session()!
		return
	}
	options := parse_prompt_options(args, false)!
	start_prompt(options.prompt, options.tools)!
}

fn print_help() {
	println('vc - compact coding agent')
	println('')
	println('Usage:')
	println('  vc [--tool read|edit|shell|web]... <prompt>')
	println('  vc model list')
	println('  vc model set <provider:model> [--effort <level>]')
	println('  vc small-model set <provider:model>')
	println('  vc session list')
	println('  vc resume <id-or-name> [--move-session]')
	println('  vc session attach <id-or-name>')
	println('  vc --rpc')
	println('  vc -p <prompt> [--tool read|edit|shell|web]...')
}

fn run_small_model(args []string) ! {
	if args.len != 2 || args[0] != 'set' {
		return error('usage: vc small-model set <provider:model>')
	}
	vc.parse_model_ref(args[1])!
	mut cfg := vc.load_config(vc.config_path())!
	cfg.small_model = args[1]
	vc.save_config(cfg, vc.config_path())!
	println(cfg.small_model)
}

fn run_scripted(args []string) ! {
	options := parse_prompt_options(args, true)!
	cfg := vc.load_config(vc.config_path())!
	result := vc.run_agent_turn_scripted(cfg.default_model, options.prompt, os.getwd(), cfg,
		options.tools)!
	for event in result.history {
		if event.kind != 'tool_call' { continue
		 }
		name := vc.json_field(event.data, 'name').to_lower()
		println(if name == 'websearch' { 'web' } else { name })
	}
	if result.answer != '' { println(result.answer) }
}

struct PromptOptions {
	prompt string
	tools  []string
}

fn parse_prompt_options(args []string, scripted bool) !PromptOptions {
	mut prompt := []string{}
	mut tools := []string{}
	mut index := 0
	for index < args.len {
		if args[index] == '-p' {
			if !scripted { prompt << args[index] }
			index++
			continue
		}
		if args[index] == '--tool' {
			if index + 1 >= args.len { return error('--tool requires read, edit, shell, or web') }
			tool := args[index + 1].to_lower()
			if tool !in ['read', 'edit', 'shell', 'web'] {
				return error('unknown tool: ${args[index + 1]}')
			}
			if tool !in tools { tools << tool }
			index += 2
			continue
		}
		prompt << args[index]
		index++
	}
	if prompt.len == 0 {
		return error(if scripted { 'vc -p requires a prompt' } else { 'prompt is required' })
	}
	return PromptOptions{
		prompt: prompt.join(' ')
		tools:  tools
	}
}

fn run_model(args []string) ! {
	mut cfg := vc.load_config(vc.config_path())!
	if args == ['list'] {
		models := vc.model_catalog(cfg)!
		println(models.join('\n'))
		return
	}
	if args.len >= 2 && args[0] == 'set' {
		vc.parse_model_ref(args[1])!
		cfg.default_model = args[1]
		effort_index := args.index('--effort')
		if effort_index >= 0 {
			if effort_index + 1 >= args.len { return error('--effort requires a value') }
			cfg.effort = args[effort_index + 1]
		}
		vc.save_config(cfg, vc.config_path())!
		println('${cfg.default_model} (${cfg.effort})')
		return
	}
	return error('usage: vc model list | vc model set <provider:model> [--effort level]')
}

fn run_session(args []string) ! {
	if args == ['list'] {
		for session in vc.list_sessions()! {
			println('${session.id}\t${session.name}\t${session.model}\t${session.cwd}\t${session.recap}')
		}
		return
	}
	if args.len >= 2 && args[0] == 'attach' {
		meta := vc.resolve_session_meta(args[1])!
		vc.start_session_worker(meta.id) or {}
		println('attached ${meta.id} (${meta.model}) in ${meta.cwd}')
		return
	}
	return error('usage: vc session list | vc session attach <id-or-name>')
}

fn run_resume(args []string) ! {
	if args.len == 0 { return error('usage: vc resume <id-or-name> [--move-session]') }
	mut meta := vc.resolve_session_meta(args[0])!
	if os.real_path(os.getwd()) != meta.cwd {
		move_allowed := '--move-session' in args
		mut confirmed := move_allowed
		if !move_allowed && os.is_atty(0) > 0 {
			print('Move session from ${meta.cwd} to ${os.getwd()}? [y/N] ')
			confirmed = os.get_line().trim_space().to_lower() in ['y', 'yes']
		}
		if confirmed {
			mut worker := vc.new_session_worker(meta)!
			_ =
				worker.handle_rpc('{"jsonrpc":"2.0","id":1,"method":"session.move","params":{"cwd":"${escape(os.getwd())}"}}')
			meta = worker.meta
		}
	}
	vc.start_session_worker(meta.id)!
	if os.is_atty(0) <= 0 { return error('vc resume requires a terminal') }
	vc.run_tui(meta)!
}

fn start_prompt(prompt string, tools []string) ! {
	cfg := vc.load_config(vc.config_path())!
	mut meta := vc.new_session_meta(cfg.default_model, cfg.effort, os.getwd())
	meta.tools = tools
	vc.save_session_meta(meta)!
	mut worker := vc.new_session_worker(meta)!
	rpc_request := '{"jsonrpc":"2.0","id":1,"method":"session.message","params":{"message":"${escape(prompt)}"}}'
	_ = worker.handle_rpc(rpc_request)
	result := vc.run_agent_turn_restricted(meta.model, prompt, meta.cwd, cfg, tools) or {
		eprintln('vc: ${err}; session ${meta.id} remains available')
		vc.AgentTurnResult{}
	}
	for event in result.history {
		record := worker.events.push(event.kind, event.data)
		worker.journal.append(record.seq, record.kind, record.data)!
	}
	answer := result.answer
	if answer != '' {
		assistant := worker.events.push('assistant', answer)
		worker.journal.append(assistant.seq, assistant.kind, assistant.data)!
	}
	vc.start_session_worker(meta.id)!
	if os.is_atty(0) > 0 { vc.run_tui(meta)! }
}

fn start_empty_session() ! {
	if os.is_atty(0) <= 0 {
		return error('interactive session requires a terminal; use vc <prompt> for noninteractive input')
	}
	cfg := vc.load_config(vc.config_path())!
	mut model := cfg.default_model
	default_ref := vc.parse_model_ref(model)!
	if default_ref.provider !in cfg.providers && cfg.providers.len > 0 {
		model = vc.fzf_select(vc.model_catalog(cfg)!, 'model> ')!
		if model == '' { return error('model selection cancelled') }
	}
	meta := vc.new_session_meta(model, cfg.effort, os.getwd())
	vc.save_session_meta(meta)!
	vc.start_session_worker(meta.id)!
	vc.run_tui(meta)!
}

fn run_stdio_rpc() ! {
	cfg := vc.load_config(vc.config_path())!
	meta := vc.new_session_meta(cfg.default_model, cfg.effort, os.getwd())
	vc.save_session_meta(meta)!
	mut worker := vc.new_session_worker(meta)!
	for {
		line := os.get_line()
		if line == '' { break
		 }
		println(worker.handle_rpc(line))
		if worker.shutdown { break
		 }
	}
}

fn escape(value string) string {
	return value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
}
