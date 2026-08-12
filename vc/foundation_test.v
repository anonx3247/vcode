module vc

import os

fn test_model_ref() {
	model := parse_model_ref('openai:gpt-5.2') or { panic(err) }
	assert model.provider == 'openai'
	assert model.model == 'gpt-5.2'
}

fn test_event_ring_is_bounded() {
	mut ring := new_event_ring(2)
	ring.push('a', '1')
	ring.push('b', '2')
	ring.push('c', '3')
	assert ring.items.len == 2
	assert ring.items[0].kind == 'b'
}

fn test_instruction_import_cycles() {
	tmp := os.join_path(os.temp_dir(), 'vc-instructions-${os.getpid()}')
	os.mkdir_all(tmp) or { panic(err) }
	defer { os.rmdir_all(tmp) or {} }
	os.write_file(os.join_path(tmp, 'AGENTS.md'), '@extra.md\nroot') or { panic(err) }
	os.write_file(os.join_path(tmp, 'extra.md'), '@AGENTS.md\nextra') or { panic(err) }
	loaded := load_instructions(tmp) or { panic(err) }
	assert loaded.content.contains('root')
	assert loaded.content.contains('extra')
	assert loaded.files.len >= 2
}
