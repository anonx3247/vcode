module vc

import os

fn test_json_array_field_handles_nested_arrays_and_brackets_in_strings() {
	source := '{"output":[{"type":"reasoning","summary":[]},{"type":"function_call","arguments":"{\\"value\\":\\"]\\"}"}],"status":"completed"}'
	value := json_array_field(source, 'output') or { panic(err) }
	assert value.contains('"type":"reasoning"')
	assert value.contains('"type":"function_call"')
}

fn test_agent_request_is_zdr_compatible() {
	body := agent_request_body('gpt-test', ['{"role":"user","content":"hello"}'])
	assert body.contains('"store":false')
	assert body.contains('"stream":true')
	assert body.contains('"reasoning.encrypted_content"')
	assert !body.contains('previous_response_id')
}

fn test_image_paths_become_openai_input_images() {
	path := os.join_path(os.temp_dir(), 'vc-agent-image-${os.getpid()}.png')
	defer { os.rm(path) or {} }
	os.write_file_array(path, [u8(137), 80, 78, 71]) or { panic(err) }
	item := user_input_item('inspect ${path}') or { panic(err) }
	assert item.contains('"type":"input_image"')
	assert item.contains('data:image/png;base64,iVBORw==')
	content := anthropic_user_content('inspect ${path}') or { panic(err) }
	assert content.contains('"type":"image"')
	assert content.contains('"media_type":"image/png"')
	assert prompt_image_paths('old /tmp/old.png\nCurrent user request:\nlook at ${path}') == [
		os.real_path(path),
	]
	assert prompt_path_tokens('inspect "/tmp/a picture.png" now') == [
		'inspect',
		'/tmp/a picture.png',
		'now',
	]
}

fn test_read_tool_schema_exposes_optional_line_range() {
	tools := agent_tool_definitions()
	assert tools.contains('"name":"Read"')
	assert tools.contains('"start":{"type":"integer"')
	assert tools.contains('"end":{"type":"integer"')
	assert tools.contains('Defaults to the first 3000 lines')
}

fn test_edit_tool_schema_allows_new_file_creation_without_fingerprint() {
	tools := agent_tool_definitions()
	edit_start := tools.index('"name":"Edit"') or { panic('Edit schema missing') }
	edit_end := tools.index_after('"name":"Shell"', edit_start) or { panic('Shell schema missing') }
	edit := tools[edit_start..edit_end]
	assert edit.contains('To create a new file without Read')
	assert edit.contains('"required":["path","old","replacement"]')
	assert !edit.contains('"required":["path","old","replacement","fingerprint"]')
}

fn test_review_tool_schema_excludes_edit() {
	tools := review_tool_definitions()
	assert tools.contains('"name":"Read"')
	assert tools.contains('"name":"Shell"')
	assert tools.contains('"name":"WebSearch"')
	assert !tools.contains('"name":"Edit"')
	execute_agent_tool_with_policy('Edit', '{"path":"x","old":"a","replacement":"b"}', '.', [
		'read',
		'shell',
		'web',
	]) or {
		assert err.msg().contains('unavailable for this agent')
		return
	}
	assert false
}

fn test_restricted_tool_schema_contains_only_requested_tools() {
	tools := tool_definitions(['web', 'shell'])
	assert tools.contains('"name":"WebSearch"')
	assert tools.contains('"name":"Shell"')
	assert !tools.contains('"name":"Read"')
	assert !tools.contains('"name":"Edit"')
}

fn test_agent_stream_collects_text_and_completed_tool_calls() {
	mut parser := new_sse_parser(4096)
	mut result := AgentStreamResponse{}
	mut display := ToolDisplayState{}
	mut raw := ''
	raw = consume_agent_stream('event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"hel', mut
		parser, mut result, mut display, raw) or { panic(err) }
	raw = consume_agent_stream('lo"}\n\nevent: response.completed\ndata: {"type":"response.completed","response":{"output":[{"type":"function_call","name":"Shell","call_id":"call-1","arguments":"{\\"command\\":\\"pwd\\"}"}],"usage":{"input_tokens":64000}}}\n\n', mut
		parser, mut result, mut display, raw) or { panic(err) }
	assert raw != ''
	assert result.answer == 'hello'
	assert result.calls.len == 1
	assert result.calls[0].name == 'Shell'
	assert result.calls[0].call_id == 'call-1'
	assert result.input_tokens == 64000
}

fn test_provider_failure_does_not_dump_buffered_sse() {
	sse := 'data: {"type":"response.created","response":{"large":"secret"}}\n\ndata: {"type":"response.in_progress"}'
	assert provider_failure_detail(sse, '') == ''
	assert provider_failure_detail(sse, 'curl: (28) Operation timed out') == 'curl: (28) Operation timed out'
	assert provider_failure_detail('{"error":"bad key"}', '') == '{"error":"bad key"}'
}
