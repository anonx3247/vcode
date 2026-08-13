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

fn test_edit_can_create_but_not_overwrite_a_new_file() {
	path := os.join_path(os.temp_dir(), 'vc-edit-create-${os.getpid()}')
	defer { os.rm(path) or {} }
	os.rm(path) or {}
	hash := edit_tool(path, '', 'new contents', '') or { panic(err) }
	assert os.read_file(path) or { panic(err) } == 'new contents'
	assert hash.len == 64
	edit_tool(path, '', 'overwritten', '') or {
		assert err.msg().contains('old text cannot be empty')
		assert os.read_file(path) or { panic(err) } == 'new contents'
		return
	}
	assert false
}

fn test_new_file_edit_rejects_old_text_and_read_fingerprints() {
	path := os.join_path(os.temp_dir(), 'vc-edit-create-invalid-${os.getpid()}')
	defer { os.rm(path) or {} }
	os.rm(path) or {}
	edit_tool(path, 'missing', 'contents', '') or {
		assert err.msg().contains('requires empty old text')
		assert !os.exists(path)
		edit_tool(path, '', 'contents', 'stale-fingerprint') or {
			assert err.msg().contains('does not accept a Read fingerprint')
			assert !os.exists(path)
			return
		}
		assert false
		return
	}
	assert false
}

fn test_read_defaults_to_3000_lines_and_supports_ranges() {
	path := os.join_path(os.temp_dir(), 'vc-read-range-${os.getpid()}')
	defer { os.rm(path) or {} }
	mut lines := []string{cap: 4000}
	for index in 1 .. 4001 {
		lines << 'line-${index}'
	}
	os.write_file(path, lines.join('\n')) or { panic(err) }
	first := read_tool(path, 1024 * 1024) or { panic(err) }
	assert first.start == 1
	assert first.end == 3000
	assert first.total_lines == 4000
	assert first.content.contains('line-1')
	assert first.content.ends_with('line-3000')
	assert !first.content.contains('line-3001')
	assert first.truncated
	range := read_tool_range(path, 3001, 3010, 1024 * 1024) or { panic(err) }
	assert range.content.starts_with('line-3001')
	assert range.content.ends_with('line-3010')
	assert range.content.split_into_lines().len == 10
	read_tool_range(path, 20, 10, 1024) or {
		assert err.msg().contains('end')
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

fn test_background_job_output_cursor() {
	mut manager := ShellJobManager{
		max_output: 4096
	}
	id := manager.start('printf one; sleep 0.05; printf two', os.temp_dir()) or { panic(err) }
	mut cursor := u64(0)
	mut output := ''
	for _ in 0 .. 100 {
		read := manager.read(id, cursor) or { panic(err) }
		output += read.output
		cursor = read.next_cursor
		if read.done { break
		 }
		time.sleep(10 * time.millisecond)
	}
	assert output.contains('one')
	assert output.contains('two')
}

fn test_malformed_stream_corpus_never_panics() {
	corpus := ['', '\r', '\n', '\033[2J', 'data:', 'event: x\n', 'data: {not-json}\n\n',
		'x'.repeat(2048)]
	for sample in corpus {
		mut parser := new_sse_parser(1024)
		_ = parser.feed(sample) or { continue }
	}
}

fn test_sse_limit_is_enforced() {
	mut parser := new_sse_parser(8)
	parser.feed('123456789') or {
		assert err.msg().contains('exceeds')
		return
	}
	assert false
}

fn test_custom_transport_reuses_incremental_sse_decoder() {
	mut parser := new_sse_parser(1024)
	mut events := []StreamEvent{}
	mut raw := ''
	raw = consume_provider_chunk('openai',
		'event: response.output_text.delta\ndata: {"type":"response.output_text.delta",', mut
		parser, mut events, raw) or { panic(err) }
	raw = consume_provider_chunk('openai', '"delta":"OK"}\n\n', mut parser, mut events, raw) or {
		panic(err)
	}
	assert raw.contains('"delta":"OK"')
	assert events.len == 1
	assert events[0].kind == .text
	assert events[0].text == 'OK'
}
