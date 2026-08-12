module vc

import net.http
import os

pub enum StreamKind {
	text
	reasoning
	tool_call
	usage
	continuation
	error
	done
}

pub struct StreamEvent {
pub:
	kind    StreamKind
	text    string
	name    string
	call_id string
	json    string
}

pub interface ProviderAdapter {
	build_request(model string, prompt string) !http.Request
	decode(message SseMessage) ![]StreamEvent
}

@[heap]
struct StreamCapture {
mut:
	provider string
	parser   SseParser
	events   []StreamEvent
	failure  string
}

fn capture_stream_body(request &http.Request, chunk []u8, body_read u64, expected u64, status int) ! {
	_ = body_read
	_ = expected
	mut capture := unsafe { &StreamCapture(request.user_ptr) }
	if status < 200 || status >= 300 {
		capture.failure = 'provider returned HTTP ${status}'
		return
	}
	messages := capture.parser.feed(chunk.bytestr()) or {
		capture.failure = err.msg()
		return
	}
	for message in messages {
		decoded := if capture.provider == 'openai' {
			OpenAIAdapter{}.decode(message) or {
				capture.failure = err.msg()
				return
			}
		} else {
			AnthropicAdapter{}.decode(message) or {
				capture.failure = err.msg()
				return
			}
		}
		capture.events << decoded
	}
}

pub fn stream_completion(model_ref string, prompt string, cfg Config) ![]StreamEvent {
	model := parse_model_ref(model_ref)!
	provider := cfg.providers[model.provider] or {
		ProviderConfig{
			name: model.provider
		}
	}
	key := if provider.api_key != '' {
		provider.api_key
	} else if model.provider == 'openai' {
		os.getenv('OPENAI_API_KEY')
	} else {
		os.getenv('ANTHROPIC_API_KEY')
	}
	if key == '' { return error('missing API key for ${model.provider}') }
	mut request := if model.provider == 'openai' {
		OpenAIAdapter{
			api_key:  key
			base_url: if provider.base_url != '' {
				provider.base_url
			} else {
				'https://api.openai.com/v1'
			}
		}.build_request(model.model, prompt)!
	} else if model.provider == 'anthropic' {
		AnthropicAdapter{
			api_key:  key
			base_url: if provider.base_url != '' {
				provider.base_url
			} else {
				'https://api.anthropic.com/v1'
			}
		}.build_request(model.model, prompt)!
	} else {
		return error('unsupported provider adapter: ${model.provider}')
	}
	mut capture := &StreamCapture{
		provider: model.provider
		parser:   new_sse_parser(1024 * 1024)
	}
	request.user_ptr = voidptr(capture)
	request.on_progress_body = capture_stream_body
	request.stop_copying_limit = 0
	request.max_retries = 2
	_ := request.do()!
	if capture.failure != '' { return error(capture.failure) }
	capture.parser.finish() or {}
	return capture.events.clone()
}

pub struct OpenAIAdapter {
pub:
	base_url string = 'https://api.openai.com/v1'
	api_key  string
}

pub fn (adapter OpenAIAdapter) build_request(model string, prompt string) !http.Request {
	body := '{"model":"${json_escape(model)}","input":"${json_escape(prompt)}","stream":true}'
	mut request := http.new_request(.post, '${adapter.base_url}/responses', body)
	request.add_header(.authorization, 'Bearer ${adapter.api_key}')
	request.add_header(.content_type, 'application/json')
	return request
}

pub fn (adapter OpenAIAdapter) decode(message SseMessage) ![]StreamEvent {
	_ = adapter
	if message.data == '[DONE]' { return [StreamEvent{ kind: .done }] }
	type_name := json_field(message.data, 'type')
	return match type_name {
		'response.output_text.delta' {
			[StreamEvent{ kind: .text, text: json_field(message.data, 'delta') }]
		}
		'response.reasoning_summary_text.delta' {
			[StreamEvent{ kind: .reasoning, text: json_field(message.data, 'delta') }]
		}
		'response.function_call_arguments.delta' {
			[
				StreamEvent{
					kind:    .tool_call
					call_id: json_field(message.data, 'item_id')
					json:    json_field(message.data, 'delta')
				},
			]
		}
		'response.completed' {
			[StreamEvent{ kind: .usage, json: message.data },
				StreamEvent{ kind: .done }]
		}
		'error' {
			[StreamEvent{ kind: .error, text: json_field(message.data, 'message') }]
		}
		else {
			[]StreamEvent{}
		}
	}
}

pub struct AnthropicAdapter {
pub:
	base_url string = 'https://api.anthropic.com/v1'
	api_key  string
}

pub fn (adapter AnthropicAdapter) build_request(model string, prompt string) !http.Request {
	body := '{"model":"${json_escape(model)}","max_tokens":4096,"stream":true,"messages":[{"role":"user","content":"${json_escape(prompt)}"}]}'
	mut request := http.new_request(.post, '${adapter.base_url}/messages', body)
	request.add_custom_header('x-api-key', adapter.api_key)!
	request.add_custom_header('anthropic-version', '2023-06-01')!
	request.add_header(.content_type, 'application/json')
	return request
}

pub fn (adapter AnthropicAdapter) decode(message SseMessage) ![]StreamEvent {
	_ = adapter
	return match message.event {
		'content_block_delta' {
			kind := if message.data.contains('"thinking_delta"') {
				'thinking_delta'
			} else if message.data.contains('"input_json_delta"') {
				'input_json_delta'
			} else {
				'text_delta'
			}
			if kind == 'thinking_delta' {
				[
					StreamEvent{
						kind: .reasoning
						text: json_field(message.data, 'thinking')
					},
				]
			} else if kind == 'input_json_delta' {
				[
					StreamEvent{
						kind: .tool_call
						json: json_field(message.data, 'partial_json')
					},
				]
			} else {
				[StreamEvent{ kind: .text, text: json_field(message.data, 'text') }]
			}
		}
		'message_delta' {
			[StreamEvent{ kind: .usage, json: message.data }]
		}
		'message_stop' {
			[StreamEvent{ kind: .done }]
		}
		'error' {
			[StreamEvent{ kind: .error, text: json_field(message.data, 'message') }]
		}
		else {
			[]StreamEvent{}
		}
	}
}

fn json_escape(value string) string {
	return value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r').replace('\t',
		'\\t')
}

fn json_field(source string, name string) string {
	needle := '"${name}"'
	start := source.index(needle) or { return '' }
	mut rest := source[start + needle.len..].trim_left(' \t\r\n:')
	if !rest.starts_with('"') {
		comma := rest.index(',') or { rest.len }
		brace := rest.index('}') or { rest.len }
		return rest[..if comma < brace {
			comma
		} else {
			brace
		}].trim_space()
	}
	rest = rest[1..]
	mut value := ''
	mut escaped := false
	for character in rest.runes() {
		if escaped {
			value += match character {
				`n` { '\n' }
				`r` { '\r' }
				`t` { '\t' }
				else { character.str() }
			}

			escaped = false
		} else if character == `\\` {
			escaped = true
		} else if character == `"` {
			break
		} else {
			value += character.str()
		}
	}
	return value
}
