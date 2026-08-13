module vc

import os

struct FakeSmallModel {
	answer string
}

struct FailingSmallModel {}

fn (model FakeSmallModel) complete(system string, prompt string, max_tokens int) !string {
	_ = system
	_ = prompt
	_ = max_tokens
	return model.answer
}

fn (model FailingSmallModel) complete(system string, prompt string, max_tokens int) !string {
	_ = model
	_ = system
	_ = prompt
	_ = max_tokens
	return error('primary unavailable')
}

fn test_compaction_preserves_transcript_and_checkpoints() {
	mut transcript := []ContextItem{}
	for index in 0 .. 30 {
		transcript << ContextItem{
			seq:     u64(index + 1)
			kind:    if index % 3 == 0 { 'tool_result' } else { 'text' }
			content: 'x'.repeat(120)
			tokens:  30
		}
	}
	original := transcript.clone()
	projection := project_context(transcript, 1000, 'small:test', FakeSmallModel{ answer: 'summary' }) or {
		panic(err)
	}
	assert transcript == original
	assert projection.items.len < transcript.len
	checkpoint := projection.checkpoint or { panic('expected checkpoint') }
	assert checkpoint.input_hash.len == 64
	assert checkpoint.result == 'summary'
}

fn test_reasoning_only_compaction_creates_a_visible_checkpoint() {
	mut transcript := []ContextItem{}
	for index in 0 .. 10 {
		transcript << ContextItem{
			seq:     u64(index + 1)
			kind:    if index < 5 { 'reasoning' } else { 'text' }
			content: 'reason-${index}'
			tokens:  70
		}
	}
	projection := project_context(transcript, 1000, 'small:test', FakeSmallModel{ answer: 'unused' }) or {
		panic(err)
	}
	checkpoint := projection.checkpoint or { panic('expected checkpoint') }
	assert checkpoint.model == ''
	assert checkpoint.result.contains('removed old reasoning')
}

fn test_recap_schedule_first_then_ten_minutes() {
	mut scheduler := RecapScheduler{}
	assert scheduler.should_recap(1000, 1)
	assert !scheduler.should_recap(2000, 2)
	assert scheduler.should_recap(1000 + 10 * 60 * 1000, 3)
}

fn test_generated_recap_is_one_safe_picker_line() {
	recap := generate_recap(FakeSmallModel{ answer: '\033[31mWorked\033[0m\non history.\tDone.' },
		'transcript') or { panic(err) }
	assert recap == 'Worked on history. Done.'
}

fn test_goal_evaluation_falls_back_when_small_model_is_unavailable() {
	judgement := evaluate_goal_with_fallback(FailingSmallModel{}, FakeSmallModel{
		answer: '<goal achieved>'
	}, 'ship it', 'done') or { panic(err) }
	assert judgement == '<goal achieved>'
}

fn test_review_has_no_edit_tool() {
	context := build_review_context('.', 'openai:test') or { panic(err) }
	assert 'Edit' !in context.tools
}

fn test_review_prompt_requires_independent_tool_use_and_final_findings() {
	context := ReviewContext{
		cwd: '/tmp/project'
	}
	prompt := review_prompt(context, 'compare a.c and a.go')
	assert prompt.contains('/tmp/project')
	assert prompt.contains('Inspect the files yourself')
	assert prompt.contains('Do not ask the user to provide files')
	assert prompt.contains('give the actual review findings')
	assert prompt.contains('compare a.c and a.go')
}

fn test_session_prompt_replays_prior_messages_and_tool_history_once() {
	old_state := os.getenv('XDG_STATE_HOME')
	tmp := os.join_path(os.temp_dir(), 'vc-context-history-${os.getpid()}')
	os.setenv('XDG_STATE_HOME', tmp, true)
	defer {
		os.setenv('XDG_STATE_HOME', old_state, true)
		os.rmdir_all(tmp) or {}
	}
	id := 'history-test'
	journal := open_journal(os.join_path(session_dir(id), 'transcript.jsonl')) or { panic(err) }
	journal.append(1, 'user', 'remember the number 41') or { panic(err) }
	journal.append(2, 'tool_call', '{"name":"Read","arguments":"README.md"}') or { panic(err) }
	journal.append(3, 'tool_result', '{"name":"Read","result":"important contents"}') or {
		panic(err)
	}
	journal.append(4, 'assistant', 'I will remember it.') or { panic(err) }
	journal.append(5, 'review', 'Finding: the bounds check is missing.') or { panic(err) }
	journal.append(6, 'user', 'what number did I give you?') or { panic(err) }
	prompt := build_session_prompt(id, 'local instructions', '', 'what number did I give you?', Config{}) or {
		panic(err)
	}
	assert prompt.contains('[User]\nremember the number 41')
	assert prompt.contains('[Tool call]')
	assert prompt.contains('important contents')
	assert prompt.contains('[Assistant]\nI will remember it.')
	assert prompt.contains('[Review findings]\nFinding: the bounds check is missing.')
	assert prompt.count('what number did I give you?') == 1
}
