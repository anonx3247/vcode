module vc

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

fn test_agent_stream_collects_text_and_completed_tool_calls() {
	mut parser := new_sse_parser(4096)
	mut result := AgentStreamResponse{}
	mut display := ToolDisplayState{}
	mut raw := ''
	raw = consume_agent_stream('event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"hel', mut
		parser, mut result, mut display, raw) or { panic(err) }
	raw = consume_agent_stream('lo"}\n\nevent: response.completed\ndata: {"type":"response.completed","response":{"output":[{"type":"function_call","name":"Shell","call_id":"call-1","arguments":"{\\"command\\":\\"pwd\\"}"}]}}\n\n', mut
		parser, mut result, mut display, raw) or { panic(err) }
	assert raw != ''
	assert result.answer == 'hello'
	assert result.calls.len == 1
	assert result.calls[0].name == 'Shell'
	assert result.calls[0].call_id == 'call-1'
}
