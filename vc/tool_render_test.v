module vc

fn test_shell_tool_card_is_structured_and_highlighted() {
	rendered := render_tool_call('Shell', '{"command":"rg --files | head -10","timeout_ms":10000}')
	plain := sanitize_terminal(rendered)
	assert rendered.contains('\x1b[')
	assert plain.contains('▶ Shell')
	assert plain.contains('│ $ rg --files | head -10')
	assert plain.contains('└ timeout 10s')
	assert !plain.contains('timeout_ms')
	assert !plain.contains('{"command"')
}

fn test_shell_result_preview_is_truncated_only_for_display() {
	mut output := ''
	for index in 0 .. 100 {
		output += 'line ${index}\n'
	}
	result := '{"output":"${json_escape(output)}","exit_code":0,"timed_out":false}'
	rendered := render_tool_result('Shell', result)
	plain := sanitize_terminal(rendered)
	assert plain.contains('◀ Shell · exit 0')
	assert plain.contains('bytes /')
	assert plain.contains('lines hidden')
	assert plain.len < output.len
	assert result.contains('line 99')
}

fn test_read_tool_card_does_not_show_raw_json() {
	rendered := render_tool_call('Read', '{"path":"README.md"}')
	plain := sanitize_terminal(rendered)
	assert plain.contains('▶ Read')
	assert plain.contains('README.md')
	assert !plain.contains('{"path"')
}

fn test_tool_result_collapse_rewinds_and_clears_rendered_rows() {
	sequence := tool_result_collapse_sequence('first\nsecond\nthird', 80)
	assert sequence == '\x1b[3A\r\x1b[J'
}

fn test_read_result_does_not_render_file_content() {
	result := '{"path":"/tmp/file","content":"secret contents","fingerprint":"abcdef1234567890","truncated":false}'
	plain := sanitize_terminal(render_tool_result('Read', result))
	assert plain.contains('/tmp/file')
	assert !plain.contains('secret contents')
}
