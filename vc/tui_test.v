module vc

import os

fn test_markdown_and_mermaid_snapshots() {
	mut renderer := MarkdownRenderer{}
	lines := renderer.render('one',
		'# title\n\n- alpha beta gamma\n\n```mermaid\nflowchart LR\nA[Start] --> B[Done]\n```\n\n$x^2$', 24)
	joined := lines.join('\n')
	assert joined.contains('TITLE')
	assert joined.contains('[Start] → [Done]')
	assert joined.contains('$x^2$')
	narrow := renderer.render('one', '| a long cell | b |', 16)
	assert narrow.len > 0
}

fn test_incomplete_fence_and_sanitization() {
	mut renderer := MarkdownRenderer{}
	lines := renderer.render('stream', 'before\n```v\nprintln(1)', 80)
	assert lines.join('\n').contains('```v')
	assert sanitize_terminal('\033[2Jhello\007') == 'hello'
}

fn test_mermaid_cycle_falls_back_to_source() {
	mut renderer := MarkdownRenderer{}
	lines := renderer.render('cycle', '```mermaid\nflowchart LR\nA --> B\nB --> A\n```', 80)
	assert lines.join('\n').contains('flowchart LR')
}

fn test_footer_at_repo_root() {
	location := detect_repo(os.getwd())
	assert location.inside
	assert location.folder == '.'
	assert footer('openai:test', os.getwd(), 3).contains('PR #3')
}

fn test_tui_queue_and_double_escape() {
	mut state := TuiState{
		busy: true
	}
	assert state.submit('later') == none
	assert state.queue == ['later']
	assert state.escape(1000) == 'interrupt'
	assert state.escape(1200) == 'cancel'
	assert state.goal_paused
}

fn test_skill_discovery_does_not_load_content() {
	state := TuiState{}
	assert state.skill_content == ''
}

fn test_direct_model_selection_does_not_discover_models() {
	old_state := os.getenv('XDG_STATE_HOME')
	tmp := os.join_path(os.temp_dir(), 'vc-tui-model-${os.getpid()}')
	os.setenv('XDG_STATE_HOME', tmp, true)
	defer {
		os.setenv('XDG_STATE_HOME', old_state, true)
		os.rmdir_all(tmp) or {}
	}
	meta := new_session_meta('openai:test', 'low', os.temp_dir())
	save_session_meta(meta) or { panic(err) }
	mut state := TuiState{
		meta: meta
	}
	message := handle_tui_command(mut state, '/model isara:test') or { panic(err) }
	assert message == 'model: isara:test'
	assert state.meta.model == 'isara:test'
}

fn test_terminal_control_corpus_is_removed() {
	for sample in ['\033]0;owned\007', '\033[31mred\033[0m', '\000x', '\033[999999z'] {
		clean := sanitize_terminal(sample)
		assert !clean.contains('\033')
		assert !clean.contains('\000')
	}
}
