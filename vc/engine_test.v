module vc

import os
import time

fn test_fragmented_sse() {
	mut parser := new_sse_parser(1024)
	mut events := []SseMessage{}
	for fragment in ['eve', 'nt: ping\r', '\ndata: hel', 'lo\r\n', 'data: world\r\n\r\n'] {
		events << parser.feed(fragment) or { panic(err) }
	}
	assert events.len == 1
	assert events[0].event == 'ping'
	assert events[0].data == 'hello\nworld'
}

fn test_openai_and_anthropic_adapters() {
	openai := OpenAIAdapter{}
	events := openai.decode(SseMessage{ data: '{"type":"response.output_text.delta","delta":"hi"}' }) or {
		panic(err)
	}
	assert events[0].text == 'hi'
	anthropic := AnthropicAdapter{}
	aevents := anthropic.decode(SseMessage{
		event: 'content_block_delta'
		data:  '{"delta":{"type":"text_delta","text":"yo"}}'
	}) or { panic(err) }
	assert aevents[0].text == 'yo'
}

fn test_edit_requires_fresh_read() {
	path := os.join_path(os.temp_dir(), 'vc-edit-${os.getpid()}')
	defer { os.rm(path) or {} }
	os.write_file(path, 'old') or { panic(err) }
	read := read_tool(path, 100) or { panic(err) }
	os.write_file(path, 'changed') or { panic(err) }
	edit_tool(path, 'old', 'new', read.fingerprint) or {
		assert err.msg().contains('changed since Read')
		return
	}
	assert false
}

fn test_shell_timeout_and_working_directory() {
	result := run_shell('pwd', os.temp_dir(), 2 * time.second, 4096)
	assert result.exit_code == 0
	assert result.output.contains(os.real_path(os.temp_dir()))
	timed := run_shell('sleep 2', os.temp_dir(), 20 * time.millisecond, 4096)
	assert timed.timed_out
}
