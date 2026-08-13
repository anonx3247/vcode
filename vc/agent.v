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
	path string
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
		for event in events {
			if event.kind == .text { answer += event.text }
			if event.kind == .error { return error(event.text) }
		}
		return AgentTurnResult{
			answer: answer
		}
	}
	key := provider_api_key(kind, provider)
	if key == '' { return error('missing API key for ${model.provider}') }
	base_url := provider_base_url(kind, provider)!
	mut input_items := ['{"role":"user","content":"${json_escape(prompt)}"}']
	mut body := agent_request_body(model.model, input_items)
	mut tool_calls := 0
	for _ in 0 .. 32 {
		response_text := post_responses_json(base_url, key, body)!
		response := json2.decode[ResponsesApiResponse](response_text)!
		mut answer := ''
		mut outputs := []string{}
		for item in response.output {
			if item.type == 'message' {
				for content in item.content {
					if content.type in ['output_text', 'text'] { answer += content.text }
				}
			} else if item.type == 'function_call' {
				if item.call_id == '' { return error('tool call did not include a call_id') }
				result := execute_agent_tool(item.name, item.arguments, cwd) or {
					'{"error":"${json_escape(err.msg())}"}'
				}
				outputs << '{"type":"function_call_output","call_id":"${json_escape(item.call_id)}","output":"${json_escape(result)}"}'
				tool_calls++
			}
		}
		if outputs.len == 0 {
			return AgentTurnResult{
				answer:     answer
				tool_calls: tool_calls
			}
		}
		raw_output := json_array_field(response_text, 'output')!
		if raw_output.trim_space() == '' {
			return error('tool response did not include output items')
		}
		input_items << raw_output
		input_items << outputs
		body = agent_request_body(model.model, input_items)
	}
	return error('tool loop exceeded 32 steps')
}

fn agent_request_body(model string, input_items []string) string {
	return '{"model":"${json_escape(model)}","input":[${input_items.join(',')}],"tools":${agent_tool_definitions()},"store":false,"include":["reasoning.encrypted_content"]}'
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
			json2.encode(read_tool(resolve_tool_path(cwd, args.path), 256 * 1024)!,
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

fn post_responses_json(base_url string, key string, body string) !string {
	curl := os.find_abs_path_of_executable('curl') or { return error('curl is required') }
	tmp := os.join_path(os.temp_dir(), 'vc-agent-${os.getpid()}-${time.now().unix_nano()}')
	os.mkdir_all(tmp)!
	os.chmod(tmp, 0o700)!
	defer { os.rmdir_all(tmp) or {} }
	headers_path := os.join_path(tmp, 'headers')
	body_path := os.join_path(tmp, 'body.json')
	response_path := os.join_path(tmp, 'response.json')
	os.write_file(headers_path, 'Authorization: Bearer ${key}\nContent-Type: application/json\n')!
	os.chmod(headers_path, 0o600)!
	os.write_file(body_path, body)!
	os.chmod(body_path, 0o600)!
	mut process := os.new_process(curl)
	process.set_args(['--silent', '--show-error', '--max-time', '300', '--max-filesize', '4194304',
		'--request', 'POST', '--header', '@${headers_path}', '--data-binary', '@${body_path}',
		'--output', response_path, '--write-out', '%{http_code}', '${base_url}/responses'])
	process.set_redirect_stdio()
	process.run()
	process.wait()
	status_text := bounded_text(process.stdout_slurp(), 32).trim_space()
	error_text := bounded_text(process.stderr_slurp(), 16 * 1024)
	code := process.code
	process.close()
	if code != 0 {
		return error('provider request failed (curl ${code}): ${sanitize_terminal(error_text).trim_space()}')
	}
	status := status_text.int()
	response := os.read_file(response_path) or { '' }
	if status < 200 || status >= 300 {
		message :=
			sanitize_terminal(bounded_text(response, 16 * 1024)).replace('\n', ' ').trim_space()
		return error('provider returned HTTP ${status}${if message == '' {
			''
		} else {
			': ${message}'
		}}')
	}
	return response
}

fn agent_tool_definitions() string {
	return '[{"type":"function","name":"Read","description":"Read a file and return its content and freshness fingerprint.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}},{"type":"function","name":"Edit","description":"Replace one exact occurrence in a file previously read with Read.","parameters":{"type":"object","properties":{"path":{"type":"string"},"old":{"type":"string"},"replacement":{"type":"string"},"fingerprint":{"type":"string"}},"required":["path","old","replacement","fingerprint"],"additionalProperties":false}},{"type":"function","name":"Shell","description":"Run a command in an isolated login shell in the session working directory.","parameters":{"type":"object","properties":{"command":{"type":"string"},"timeout_ms":{"type":"integer"}},"required":["command"],"additionalProperties":false}},{"type":"function","name":"WebSearch","description":"Search the web with Brave Search.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}}]'
}
