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
	if args.len > 0 && args[0] == 'session' {
		run_session(args[1..])!
		return
	}
	if args.len == 0 {
		start_empty_session()!
		return
	}
	start_prompt(args.join(' '))!
}

fn print_help() {
	println('vc - compact coding agent')
	println('')
	println('Usage:')
	println('  vc [prompt]')
	println('  vc model list')
	println('  vc model set <provider:model> [--effort <level>]')
	println('  vc session list')
	println('  vc session attach <id> [--move-session]')
	println('  vc --rpc')
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
			println('${session.id}\t${session.model}\t${session.cwd}\t${session.recap}')
		}
		return
	}
	if args.len >= 2 && args[0] == 'attach' {
		mut meta := vc.load_session_meta(args[1])!
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
		vc.start_session_worker(meta.id) or {}
		if os.is_atty(0) > 0 {
			vc.run_tui(meta)!
		} else {
			println('attached ${meta.id} (${meta.model}) in ${meta.cwd}')
		}
		return
	}
	return error('usage: vc session list | vc session attach <id>')
}

fn start_prompt(prompt string) ! {
	cfg := vc.load_config(vc.config_path())!
	meta := vc.new_session_meta(cfg.default_model, cfg.effort, os.getwd())
	vc.save_session_meta(meta)!
	mut worker := vc.new_session_worker(meta)!
	request := '{"jsonrpc":"2.0","id":1,"method":"session.message","params":{"message":"${escape(prompt)}"}}'
	_ = worker.handle_rpc(request)
	events := vc.stream_completion(meta.model, prompt, cfg) or {
		eprintln('vc: ${err}; session ${meta.id} remains available')
		[]vc.StreamEvent{}
	}
	mut answer := ''
	for event in events {
		if event.kind == .text {
			answer += event.text
			print(event.text)
		}
	}
	if answer != '' {
		println('')
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
