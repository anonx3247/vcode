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

fn test_custom_provider_kind_and_environment_routing() {
	os.setenv('VC_TEST_BASE_URL', 'https://proxy.example/v1', true)
	os.setenv('VC_TEST_API_KEY', 'test-key', true)
	provider := ProviderConfig{
		name:         'isara'
		kind:         'openai'
		base_url_env: 'VC_TEST_BASE_URL'
		api_key_env:  'VC_TEST_API_KEY'
	}
	assert provider_kind('isara', provider) or { panic(err) } == 'openai'
	assert provider_base_url('openai', provider) == 'https://proxy.example/v1'
	assert provider_api_key('openai', provider) == 'test-key'
}

fn test_model_catalog_requires_configured_providers() {
	model_catalog(Config{}) or {
		assert err.msg().contains('no providers configured')
		return
	}
	assert false
}

fn test_parse_model_ids_deduplicates_and_preserves_provider_order() {
	models := parse_model_ids('{"data":[{"id":"gpt-5.6-sol"},{"id":"claude-opus-5"},{"id":"gpt-5.6-sol"}]}') or {
		panic(err)
	}
	assert models == ['gpt-5.6-sol', 'claude-opus-5']
}

fn test_parse_model_ids_rejects_empty_responses() {
	parse_model_ids('{"data":[]}') or {
		assert err.msg() == 'empty model list'
		return
	}
	assert false
}
