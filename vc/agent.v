module vc

import json2
import os
import time

struct ResponsesApiResponse {
	id     string
	output []ResponsesOutputItem
}

struct ResponsesOutputItem {
	type      string
	name      string
	call_id   string
	arguments string
	content   []ResponsesContent
}

struct ResponsesContent {
	type string
	text string
}

struct ReadArguments {
	path  string
	start int
	end   int
}

struct EditArguments {
	path        string
	old         string
	replacement string
	fingerprint string
}

struct ShellArguments {
	command    string
	timeout_ms int
}

struct SearchArguments {
	query string
}

pub struct AgentTurnResult {
pub:
	answer     string
	tool_calls int
	streamed   bool
	history    []AgentHistoryEvent
}

pub struct AgentHistoryEvent {
pub:
	kind string
	data string
}

pub fn run_agent_turn(model_ref string, prompt string, cwd string, cfg Config) !AgentTurnResult {
	model := parse_model_ref(model_ref)!
	provider := cfg.providers[model.provider] or {
		ProviderConfig{
			name: model.provider
		}
	}
	kind := provider_kind(model.provider, provider)!
	if kind != 'openai' {
		events := stream_completion(model_ref, prompt, cfg)!
		mut answer := ''
		mut markdown := MarkdownStreamState{}
		markdown.begin()
		for event in events {
			if event.kind == .text {
				answer += event.text
				print(markdown.push(event.text, terminal_columns()))
				flush_stdout()
			}
			if event.kind == .error { return error(event.text) }
		}
		print(markdown.finish(terminal_columns()))
		flush_stdout()
		return AgentTurnResult{
			answer:   answer
			streamed: true
		}
	}
	key := provider_api_key(kind, provider)
	if key == '' { return error('missing API key for ${model.provider}') }
	base_url := provider_base_url(kind, provider)!
	mut input_items := ['{"role":"user","content":"${json_escape(prompt)}"}']
	mut body := agent_request_body(model.model, input_items)
	mut tool_calls := 0
	mut display := ToolDisplayState{}
	mut history := []AgentHistoryEvent{}
	for _ in 0 .. 32 {
		display.markdown.begin()
		response := stream_agent_response(base_url, key, body, mut display)!
		mut outputs := []string{}
		for call in response.calls {
			if call.call_id == '' { return error('tool call did not include a call_id') }
			collapse_visible_tool_result(display.expanded_result)
			display.expanded_result = ''
			call_line := render_tool_call(call.name, call.arguments)
			println(call_line)
			history << AgentHistoryEvent{
				kind: 'tool_call'
				data: '{"name":"${json_escape(call.name)}","arguments":${json2.encode(call.arguments)}}'
			}
			result := execute_agent_tool(call.name, call.arguments, cwd) or {
				'{"error":"${json_escape(err.msg())}"}'
			}
			history << AgentHistoryEvent{
				kind: 'tool_result'
				data: '{"name":"${json_escape(call.name)}","result":${json2.encode(result)}}'
			}
			if tool_result_failed(call.name, result) {
				replace_visible_tool_call(call_line, render_failed_tool_call(call.name,
					call.arguments))
			}
			if call.name != 'Read' {
				display.expanded_result = render_tool_result(call.name, result, call.arguments)
				if display.expanded_result != '' { println(display.expanded_result) }
			}
			outputs << '{"type":"function_call_output","call_id":"${json_escape(call.call_id)}","output":"${json_escape(result)}"}'
			tool_calls++
		}
		if outputs.len == 0 {
			return AgentTurnResult{
				answer:     response.answer
				tool_calls: tool_calls
				streamed:   true
				history:    history
			}
		}
		if response.raw_output.trim_space() == '' {
			return error('tool response did not include output items')
		}
		input_items << response.raw_output
		input_items << outputs
		body = agent_request_body(model.model, input_items)
	}
	return error('tool loop exceeded 32 steps')
}

fn agent_request_body(model string, input_items []string) string {
	return '{"model":"${json_escape(model)}","input":[${input_items.join(',')}],"tools":${agent_tool_definitions()},"store":false,"include":["reasoning.encrypted_content"],"stream":true}'
}

struct AgentStreamResponse {
mut:
	answer     string
	raw_output string
	calls      []ResponsesOutputItem
}

fn stream_agent_response(base_url string, key string, body string, mut display ToolDisplayState) !AgentStreamResponse {
	curl := os.find_abs_path_of_executable('curl') or { return error('curl is required') }
	tmp := os.join_path(os.temp_dir(), 'vc-agent-${os.getpid()}-${time.now().unix_nano()}')
	os.mkdir_all(tmp)!
	os.chmod(tmp, 0o700)!
	defer { os.rmdir_all(tmp) or {} }
	headers_path := os.join_path(tmp, 'headers')
	body_path := os.join_path(tmp, 'body.json')
	os.write_file(headers_path, 'Authorization: Bearer ${key}\nContent-Type: application/json\n')!
	os.chmod(headers_path, 0o600)!
	os.write_file(body_path, body)!
	os.chmod(body_path, 0o600)!
	mut process := os.new_process(curl)
	process.set_args(['--silent', '--show-error', '--no-buffer', '--fail-with-body', '--max-time',
		'300', '--request', 'POST', '--header', '@${headers_path}', '--data-binary', '@${body_path}',
		'${base_url}/responses'])
	process.set_redirect_stdio()
	process.run()
	display.spinner.begin()
	defer { display.spinner.stop() }
	mut parser := new_sse_parser(1024 * 1024)
	mut result := AgentStreamResponse{}
	mut raw_error := ''
	mut errors := ''
	for process.is_alive() {
		display.spinner.tick(time.now().unix_milli())
		raw_error = consume_agent_stream(process.stdout_read(), mut parser, mut result, mut
			display, raw_error)!
		errors = bounded_text(errors + process.stderr_read(), 16 * 1024)
		time.sleep(5 * time.millisecond)
	}
	process.wait()
	raw_error = consume_agent_stream(process.stdout_slurp(), mut parser, mut result, mut display,
		raw_error)!
	errors = bounded_text(errors + process.stderr_slurp(), 16 * 1024)
	code := process.code
	process.close()
	if code != 0 {
		message :=
			sanitize_terminal(if raw_error.trim_space() != '' { raw_error } else { errors }).replace('\n', ' ').trim_space()
		return error('provider request failed (curl ${code})${if message == '' {
			''
		} else {
			': ${message}'
		}}')
	}
	parser.finish()!
	return result
}

fn consume_agent_stream(chunk string, mut parser SseParser, mut result AgentStreamResponse, mut display ToolDisplayState, raw_error string) !string {
	if chunk == '' { return raw_error }
	updated_error := bounded_text(raw_error + chunk, 16 * 1024)
	for message in parser.feed(chunk)! {
		type_name := json_field(message.data, 'type')
		if type_name == 'response.output_item.added'
			&& message.data.contains('"type":"function_call"') {
			display.spinner.stop()
			collapse_visible_tool_result(display.expanded_result)
			display.expanded_result = ''
		} else if type_name == 'response.output_text.delta' {
			display.spinner.stop()
			delta := json_field(message.data, 'delta')
			result.answer += delta
			print(display.markdown.push(delta, terminal_columns()))
			flush_stdout()
		} else if type_name == 'response.completed' {
			display.spinner.stop()
			print(display.markdown.finish(terminal_columns()))
			flush_stdout()
			result.raw_output = json_array_field(message.data, 'output')!
			decoded := json2.decode[ResponsesApiResponse]('{"output":[${result.raw_output}]}')!
			for item in decoded.output {
				if item.type == 'function_call' { result.calls << item }
			}
		} else if type_name == 'error' {
			display.spinner.stop()
			return error(json_field(message.data, 'message'))
		}
	}
	return updated_error
}

fn json_array_field(source string, name string) !string {
	field_start := source.index('"${name}"') or { return error('missing JSON field: ${name}') }
	after_field := source[field_start + name.len + 2..]
	colon := after_field.index(':') or { return error('invalid JSON field: ${name}') }
	array_offset := after_field[colon + 1..].index('[') or {
		return error('JSON field ${name} is not an array')
	}
	start := field_start + name.len + 2 + colon + 1 + array_offset
	mut depth := 0
	mut in_string := false
	mut escaped := false
	for index := start; index < source.len; index++ {
		character := source[index]
		if in_string {
			if escaped {
				escaped = false
			} else if character == `\\` {
				escaped = true
			} else if character == `"` {
				in_string = false
			}
			continue
		}
		if character == `"` {
			in_string = true
		} else if character == `[` {
			depth++
		} else if character == `]` {
			depth--
			if depth == 0 { return source[start + 1..index] }
		}
	}
	return error('unterminated JSON array: ${name}')
}

fn execute_agent_tool(name string, arguments string, cwd string) !string {
	return match name {
		'Read' {
			args := json2.decode[ReadArguments](arguments)!
			if args.path == '' { return error('Read requires path') }
			json2.encode(read_tool_range(resolve_tool_path(cwd, args.path), args.start, args.end,
				256 * 1024)!,
				escape_unicode: true
			)
		}
		'Edit' {
			args := json2.decode[EditArguments](arguments)!
			if args.path == '' { return error('Edit requires path') }
			hash := edit_tool(resolve_tool_path(cwd, args.path), args.old, args.replacement,
				args.fingerprint)!
			'{"fingerprint":"${json_escape(hash)}"}'
		}
		'Shell' {
			args := json2.decode[ShellArguments](arguments)!
			if args.command == '' { return error('Shell requires command') }
			mut timeout_ms := if args.timeout_ms > 0 { args.timeout_ms } else { 30_000 }
			if timeout_ms > 300_000 { timeout_ms = 300_000 }
			json2.encode(run_shell(args.command, cwd, time.Duration(timeout_ms) * time.millisecond,
				256 * 1024), escape_unicode: true)
		}
		'WebSearch' {
			args := json2.decode[SearchArguments](arguments)!
			if args.query == '' { return error('WebSearch requires query') }
			brave_web_search(args.query, os.getenv('BRAVE_API_KEY'), 256 * 1024)!
		}
		else {
			return error('unknown tool: ${name}')
		}
	}
}

fn resolve_tool_path(cwd string, path string) string {
	return if os.is_abs_path(path) { path } else { os.join_path(cwd, path) }
}

fn agent_tool_definitions() string {
	return '[{"type":"function","name":"Read","description":"Read a 1-based inclusive line range from a file and return its content and whole-file freshness fingerprint. Defaults to the first 3000 lines.","parameters":{"type":"object","properties":{"path":{"type":"string"},"start":{"type":"integer","minimum":1},"end":{"type":"integer","minimum":1}},"required":["path"],"additionalProperties":false}},{"type":"function","name":"Edit","description":"Replace one exact occurrence in an existing file using a fresh Read fingerprint. To create a new file without Read, use empty old text and omit fingerprint (or use fingerprint 0).","parameters":{"type":"object","properties":{"path":{"type":"string"},"old":{"type":"string"},"replacement":{"type":"string"},"fingerprint":{"type":"string"}},"required":["path","old","replacement"],"additionalProperties":false}},{"type":"function","name":"Shell","description":"Run a command in an isolated login shell in the session working directory.","parameters":{"type":"object","properties":{"command":{"type":"string"},"timeout_ms":{"type":"integer"}},"required":["command"],"additionalProperties":false}},{"type":"function","name":"WebSearch","description":"Search the web with Brave Search.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}}]'
}
