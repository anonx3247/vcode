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

fn test_journal_recent_read_is_bounded_to_complete_records() {
	tmp := os.join_path(os.temp_dir(), 'vc-journal-tail-${os.getpid()}.jsonl')
	defer { os.rm(tmp) or {} }
	journal := open_journal(tmp) or { panic(err) }
	for index in 0 .. 8 {
		journal.append(u64(index + 1), 'user', 'message-${index}-' + 'x'.repeat(40)) or {
			panic(err)
		}
	}
	recent := journal.read_recent(240) or { panic(err) }
	assert recent.len > 0
	assert recent.len < 8
	assert recent#[-1..][0].data.starts_with('message-7-')
	assert recent.all(it.data.starts_with('message-'))
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
	assert provider_base_url('openai', provider) or { panic(err) } == 'https://proxy.example/v1'
	assert provider_api_key('openai', provider) == 'test-key'
}

fn test_configured_provider_base_url_environment_is_required() {
	os.unsetenv('VC_TEST_MISSING_BASE_URL')
	provider := ProviderConfig{
		name:         'isara'
		kind:         'openai'
		base_url_env: 'VC_TEST_MISSING_BASE_URL'
	}
	provider_base_url('openai', provider) or {
		assert err.msg().contains('VC_TEST_MISSING_BASE_URL is not set')
		return
	}
	assert false
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
