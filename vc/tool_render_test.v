module vc

fn test_shell_tool_card_is_structured_and_highlighted() {
	rendered := render_tool_call('Shell', '{"command":"rg --files | head -10","timeout_ms":10000}')
	plain := sanitize_terminal(rendered)
	assert rendered.contains('\x1b[')
	assert plain == 'Shell $ rg --files | head -10'
	assert rendered.contains('\x1b[36mrg')
	assert rendered.contains('\x1b[35m--files')
	assert !plain.contains('timeout_ms')
	assert !plain.contains('{"command"')
}

fn test_shell_result_preview_is_truncated_only_for_display() {
	mut output := ''
	for index in 0 .. 100 {
		output += 'line ${index}\n'
	}
	result := '{"output":"${json_escape(output)}","exit_code":0,"timed_out":false}'
	rendered := render_tool_result('Shell', result, '{}')
	plain := sanitize_terminal(rendered)
	assert plain.contains('bytes /')
	assert plain.contains('lines hidden')
	assert plain.len < output.len
	assert result.contains('line 99')
}

fn test_read_tool_card_does_not_show_raw_json() {
	rendered := render_tool_call('Read', '{"path":"README.md"}')
	plain := sanitize_terminal(rendered)
	assert plain.starts_with('Read ')
	assert plain.contains('README.md')
	assert !plain.contains('{"path"')
}

fn test_tool_result_collapse_rewinds_and_clears_rendered_rows() {
	sequence := tool_result_collapse_sequence('first\nsecond\nthird', 80)
	assert sequence == '\x1b[3A\r\x1b[J'
}

fn test_read_result_does_not_render_file_content() {
	result := '{"path":"/tmp/file","content":"secret contents","fingerprint":"abcdef1234567890","truncated":false}'
	plain := sanitize_terminal(render_tool_result('Read', result, '{"path":"/tmp/file"}'))
	assert plain == ''
	assert !plain.contains('secret contents')
}

fn test_failed_tool_call_reuses_input_and_turns_red() {
	rendered := render_failed_tool_call('Shell', '{"command":"false","timeout_ms":1000}')
	plain := sanitize_terminal(rendered)
	assert rendered.contains('\x1b[1;31m')
	assert plain == 'Shell $ false · failed'
}

fn test_edit_result_renders_colored_syntax_highlighted_diff() {
	arguments := '{"path":"main.v","old":"fn old() { return 1 }","replacement":"fn new() { return 2 }","fingerprint":"abc"}'
	rendered := render_tool_result('Edit', '{"fingerprint":"next"}', arguments)
	plain := sanitize_terminal(rendered)
	assert plain.contains('- fn old() { return 1 }')
	assert plain.contains('+ fn new() { return 2 }')
	assert rendered.contains('\x1b[31m- ')
	assert rendered.contains('\x1b[32m+ ')
	assert rendered.contains('\x1b[36mfn')
}
