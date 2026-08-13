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
	assert body.contains('"reasoning.encrypted_content"')
	assert !body.contains('previous_response_id')
}
