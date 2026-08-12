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
	if args.len == 0 { return error('usage: vc [options] <prompt>') }
	start_prompt(args.join(' '))!
}

fn run_model(args []string) ! {
	mut cfg := vc.load_config(vc.config_path())!
	if args == ['list'] {
		models := ['openai:gpt-5.2', 'openai:gpt-5-mini', 'anthropic:claude-sonnet-4-5',
			'anthropic:claude-opus-4-5']
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
		meta := vc.load_session_meta(args[1])!
		println('attached ${meta.id} (${meta.model}) in ${meta.cwd}')
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
	vc.start_session_worker(meta.id)!
	println('session ${meta.id}: ${prompt}')
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
